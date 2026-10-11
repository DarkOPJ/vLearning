"""vLearning engine: TTS (Breeze) and text cleanup (S1-mini).

A small local HTTP service that loads a TTS model on demand, synthesizes one
sentence at a time, and fully unloads when told to. The app starts this process
when you press "Generate", sends sentences one by one, and calls /shutdown when
its queue is empty so every byte of model memory is returned to the system.

Only the Python standard library is used for the server itself; the model
backend uses mlx-audio (installed in the lab venv).

Endpoints (all JSON unless noted):
  GET  /health      -> {"status", "loaded", "busy", "model"}
  POST /load        {"model"?}                       -> {"loaded": true, "seconds"}
  POST /synthesize  {"text", "instruct"?, "voice"?, "speed"?, "ref_audio"?, "ref_text"?}
                    ref_audio is a file path on this Mac; with it the voice is cloned from that
                    recording (ref_text is its exact transcript) and instruct is ignored.
                    -> audio/wav body; headers X-Audio-Duration, X-Gen-Seconds
  POST /normalize   {"text", "styling"?}             -> {"text", "seconds"}
  POST /unload      -> {"loaded": false}   (unloads every model)
  POST /shutdown    -> unloads, then exits the process
"""

from __future__ import annotations

import argparse
import gc
import inspect
import io
import json
import os
import math
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

DEFAULT_MODEL = "mlx-community/Breeze-TTS-2-mlx-8bit"
DEFAULT_NORMALIZER = "mlx-community/S1-mini-MLX-8bit"
DEFAULT_INSTRUCT = "A calm, warm male narrator with a clear, steady pace, like an audiobook reader."
MAX_TEXT_CHARS = 2000
MAX_NORMALIZE_CHARS = 200_000
NORMALIZE_CHUNK_CHARS = 2500  # S1-mini is trained on inputs up to ~1000 tokens

# S1-mini's input format: this exact system prompt, then a control line. See the model card.
S1_SYSTEM = (
    "You are a text normalizer for speech-to-text transcripts. The input begins "
    "with a control line specifying the styling, structure, and context settings; "
    "clean the transcript to match those settings and output only the cleaned text."
)
S1_STYLINGS = {"casual", "semi-casual", "semi-formal", "formal"}


# --------------------------------------------------------------------------- backends


class MLXBackend:
    """Wraps an mlx-audio TTS model."""

    def __init__(self, model_id: str):
        self.model_id = model_id
        self.model = None
        self._reference = None  # (path, mtime, loaded audio): the same clip serves every sentence

    @property
    def loaded(self) -> bool:
        return self.model is not None

    def load(self) -> None:
        if self.model is not None:
            return
        from mlx_audio.tts.utils import load_model

        self.model = load_model(self.model_id)

    def synthesize(self, text: str, instruct: str | None, voice: str | None, speed: float,
                   ref_audio: str | None = None, ref_text: str | None = None):
        kwargs = {"text": text, "speed": speed, "lang_code": "en", "verbose": False}
        if ref_audio:
            # Voice cloning: no instruct, and cfg_scale stays at the model's own default.
            kwargs["ref_audio"] = self._load_reference(ref_audio)
            if ref_text:
                kwargs["ref_text"] = ref_text
        elif instruct:
            kwargs["instruct"] = instruct
        if voice:
            kwargs["voice"] = voice
        kwargs = _filter_kwargs(self.model.generate, kwargs)

        chunks, sample_rate = [], None
        for result in self.model.generate(**kwargs):
            chunks.append(np.asarray(result.audio, dtype=np.float32).reshape(-1))
            sample_rate = getattr(result, "sample_rate", None) or sample_rate
        sample_rate = sample_rate or getattr(self.model, "sample_rate", 24000)
        audio = np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32)
        return audio, int(sample_rate)

    def _load_reference(self, path: str):
        """Loads the reference clip the way mlx-audio's own CLI does, once per file version."""
        mtime = os.path.getmtime(path)
        if self._reference and self._reference[:2] == (path, mtime):
            return self._reference[2]
        if getattr(self.model, "preserve_ref_audio_path", False) is True:
            audio = path  # this model reads the file itself
        else:
            from mlx_audio.utils import load_audio

            audio = load_audio(path, sample_rate=self.model.sample_rate)
        self._reference = (path, mtime, audio)
        return audio

    def unload(self) -> None:
        self.model = None
        self._reference = None
        _release_mlx_memory()


class FakeBackend:
    """Sine-wave backend for testing the server without a model or a Mac."""

    model_id = "fake"

    def __init__(self, *_):
        self._loaded = False

    @property
    def loaded(self) -> bool:
        return self._loaded

    def load(self) -> None:
        time.sleep(0.2)
        self._loaded = True

    def synthesize(self, text, instruct, voice, speed, ref_audio=None, ref_text=None):
        sr = 24000
        seconds = max(0.3, len(text.split()) * 0.35 / max(speed, 0.1))
        t = np.arange(int(sr * seconds)) / sr
        return (0.2 * np.sin(2 * math.pi * 220 * t)).astype(np.float32), sr

    def unload(self) -> None:
        self._loaded = False


class S1Backend:
    """S1-mini text normalizer via mlx-lm."""

    def __init__(self, model_id: str):
        self.model_id = model_id
        self.model = None
        self.tokenizer = None

    @property
    def loaded(self) -> bool:
        return self.model is not None

    def load(self) -> None:
        if self.model is not None:
            return
        from mlx_lm import load

        self.model, self.tokenizer = load(self.model_id)

    def normalize(self, text: str, styling: str) -> str:
        from mlx_lm import generate

        control = f"[Styling: {styling}] [Structure: prose] [Context: general]"
        messages = [
            {"role": "system", "content": S1_SYSTEM},
            {"role": "user", "content": f"{control}\n{text}"},
        ]
        prompt = self.tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True, enable_thinking=False
        )
        # Card guidance: max_new_tokens ~ 1.3 x input tokens + 32.
        max_tokens = int(len(self.tokenizer.encode(text)) * 1.3) + 32
        return generate(self.model, self.tokenizer, prompt=prompt, max_tokens=max_tokens, verbose=False).strip()

    def unload(self) -> None:
        self.model = None
        self.tokenizer = None
        _release_mlx_memory()


class FakeNormalizer:
    model_id = "fake-normalizer"

    def __init__(self, *_):
        self._loaded = False

    @property
    def loaded(self) -> bool:
        return self._loaded

    def load(self) -> None:
        self._loaded = True

    def normalize(self, text: str, styling: str) -> str:
        lines = [l.strip() for l in text.splitlines() if l.strip()]
        return "\n".join(l[0].upper() + l[1:] + ("" if l[-1] in ".!?" else ".") for l in lines)

    def unload(self) -> None:
        self._loaded = False


def _release_mlx_memory() -> None:
    gc.collect()
    try:
        import mlx.core as mx

        clear = getattr(mx, "clear_cache", None) or mx.metal.clear_cache
        clear()
    except Exception:
        pass


def chunk_text(text: str, limit: int = NORMALIZE_CHUNK_CHARS) -> list[str]:
    """Splits at line boundaries into chunks under `limit` chars (a longer single line stays whole)."""
    chunks, current = [], []
    size = 0
    for line in text.splitlines():
        if current and size + len(line) > limit:
            chunks.append("\n".join(current))
            current, size = [], 0
        current.append(line)
        size += len(line) + 1
    if current:
        chunks.append("\n".join(current))
    return [c for c in chunks if c.strip()]


def _filter_kwargs(fn, kwargs: dict) -> dict:
    """Drop kwargs a model's generate() does not accept (models differ)."""
    try:
        params = inspect.signature(fn).parameters
    except (TypeError, ValueError):
        return kwargs
    if any(p.kind is inspect.Parameter.VAR_KEYWORD for p in params.values()):
        return kwargs
    return {k: v for k, v in kwargs.items() if k in params}


def to_wav_bytes(audio: np.ndarray, sample_rate: int) -> bytes:
    pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(pcm.tobytes())
    return buf.getvalue()


# --------------------------------------------------------------------------- engine


class Engine:
    """Holds the models and guarantees one job at a time, with only one model in memory."""

    def __init__(self, backend, normalizer):
        self.backend = backend
        self.normalizer = normalizer
        self.lock = threading.Lock()  # serializes load / synthesize / normalize / unload
        self.busy = False

    def health(self) -> dict:
        return {
            "status": "ok",
            "loaded": self.backend.loaded,
            "normalizer_loaded": self.normalizer.loaded,
            "busy": self.busy,
            "model": self.backend.model_id,
            "normalizer": self.normalizer.model_id,
        }

    def normalize(self, text: str, styling: str):
        with self.lock:
            self.busy = True
            try:
                if self.backend.loaded:
                    self.backend.unload()  # keep only one model in memory
                self.normalizer.load()
                start = time.perf_counter()
                out = "\n".join(self.normalizer.normalize(c, styling) for c in chunk_text(text))
                return out, time.perf_counter() - start
            finally:
                self.busy = False

    def load(self) -> float:
        with self.lock:
            start = time.perf_counter()
            self.backend.load()
            return time.perf_counter() - start

    def synthesize(self, text: str, instruct, voice, speed: float, ref_audio=None, ref_text=None):
        with self.lock:
            self.busy = True
            try:
                if self.normalizer.loaded:
                    self.normalizer.unload()  # keep only one model in memory
                self.backend.load()  # no-op if already loaded
                start = time.perf_counter()
                audio, sr = self.backend.synthesize(text, instruct, voice, speed, ref_audio, ref_text)
                return audio, sr, time.perf_counter() - start
            finally:
                self.busy = False

    def unload(self) -> None:
        with self.lock:
            self.backend.unload()
            self.normalizer.unload()


# --------------------------------------------------------------------------- http


def make_handler(engine: Engine, server_ref: dict):
    class Handler(BaseHTTPRequestHandler):
        server_version = "vLearningEngine/1"

        def log_message(self, fmt, *args):
            sys.stderr.write("[engine] " + (fmt % args) + "\n")

        def _json(self, code: int, payload: dict) -> None:
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _read_json(self) -> dict:
            length = int(self.headers.get("Content-Length") or 0)
            if not length:
                return {}
            return json.loads(self.rfile.read(length) or b"{}")

        def do_GET(self):
            if self.path == "/health":
                return self._json(200, engine.health())
            self._json(404, {"error": "not found"})

        def do_POST(self):
            try:
                data = self._read_json()
            except json.JSONDecodeError:
                return self._json(400, {"error": "invalid json"})

            try:
                if self.path == "/load":
                    seconds = engine.load()
                    return self._json(200, {"loaded": True, "seconds": round(seconds, 3)})

                if self.path == "/synthesize":
                    text = (data.get("text") or "").strip()
                    if not text:
                        return self._json(400, {"error": "text is required"})
                    if len(text) > MAX_TEXT_CHARS:
                        return self._json(400, {"error": f"text over {MAX_TEXT_CHARS} chars"})
                    speed = float(data.get("speed") or 1.0)
                    ref_audio = data.get("ref_audio") or None
                    ref_text = (data.get("ref_text") or "").strip() or None
                    if ref_audio:
                        if not os.path.isfile(ref_audio):
                            return self._json(400, {"error": f"reference audio not found: {ref_audio}"})
                        instruct = None  # the reference sets the voice
                    else:
                        instruct = data.get("instruct", DEFAULT_INSTRUCT)
                    audio, sr, gen = engine.synthesize(text, instruct, data.get("voice"), speed,
                                                       ref_audio, ref_text)
                    body = to_wav_bytes(audio, sr)
                    self.send_response(200)
                    self.send_header("Content-Type", "audio/wav")
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("X-Audio-Duration", f"{len(audio) / sr:.3f}")
                    self.send_header("X-Gen-Seconds", f"{gen:.3f}")
                    self.end_headers()
                    self.wfile.write(body)
                    return

                if self.path == "/normalize":
                    text = data.get("text") or ""
                    if len(text) > MAX_NORMALIZE_CHARS:
                        return self._json(400, {"error": f"text over {MAX_NORMALIZE_CHARS} chars"})
                    styling = data.get("styling") or "formal"
                    if styling not in S1_STYLINGS:
                        return self._json(400, {"error": f"styling must be one of {sorted(S1_STYLINGS)}"})
                    if not text.strip():
                        return self._json(200, {"text": "", "seconds": 0})
                    out, seconds = engine.normalize(text, styling)
                    return self._json(200, {"text": out, "seconds": round(seconds, 3)})

                if self.path == "/unload":
                    engine.unload()
                    return self._json(200, {"loaded": False})

                if self.path == "/shutdown":
                    engine.unload()
                    self._json(200, {"shutting_down": True})
                    threading.Thread(target=server_ref["server"].shutdown, daemon=True).start()
                    return
            except Exception as exc:  # report model errors to the app instead of dropping the connection
                return self._json(500, {"error": f"{type(exc).__name__}: {exc}"})

            self._json(404, {"error": "not found"})

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser(description="vLearning TTS engine")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--normalizer", default=DEFAULT_NORMALIZER)
    parser.add_argument("--preload", action="store_true", help="load the model at startup")
    parser.add_argument("--fake", action="store_true", help="sine-wave backend for testing")
    args = parser.parse_args()

    backend = FakeBackend() if args.fake else MLXBackend(args.model)
    normalizer = FakeNormalizer() if args.fake else S1Backend(args.normalizer)
    engine = Engine(backend, normalizer)
    if args.preload:
        engine.load()

    server_ref: dict = {}
    server = ThreadingHTTPServer((args.host, args.port), make_handler(engine, server_ref))
    server_ref["server"] = server
    print(f"[engine] listening on http://{args.host}:{args.port} model={backend.model_id}", flush=True)
    try:
        server.serve_forever()
    finally:
        engine.unload()
        server.server_close()
        print("[engine] stopped", flush=True)


if __name__ == "__main__":
    main()
