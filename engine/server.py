"""vLearning TTS engine.

A small local HTTP service that loads a TTS model on demand, synthesizes one
sentence at a time, and fully unloads when told to. The app starts this process
when you press "Generate", sends sentences one by one, and calls /shutdown when
its queue is empty so every byte of model memory is returned to the system.

Only the Python standard library is used for the server itself; the model
backend uses mlx-audio (installed in the lab venv).

Endpoints (all JSON unless noted):
  GET  /health      -> {"status", "loaded", "busy", "model"}
  POST /load        {"model"?}                       -> {"loaded": true, "seconds"}
  POST /synthesize  {"text", "instruct"?, "voice"?, "speed"?}
                    -> audio/wav body; headers X-Audio-Duration, X-Gen-Seconds
  POST /unload      -> {"loaded": false}
  POST /shutdown    -> unloads, then exits the process
"""

from __future__ import annotations

import argparse
import gc
import inspect
import io
import json
import math
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

DEFAULT_MODEL = "mlx-community/Breeze-TTS-2-mlx-8bit"
DEFAULT_INSTRUCT = "A calm, warm male narrator with a clear, steady pace, like an audiobook reader."
MAX_TEXT_CHARS = 2000


# --------------------------------------------------------------------------- backends


class MLXBackend:
    """Wraps an mlx-audio TTS model."""

    def __init__(self, model_id: str):
        self.model_id = model_id
        self.model = None

    @property
    def loaded(self) -> bool:
        return self.model is not None

    def load(self) -> None:
        if self.model is not None:
            return
        from mlx_audio.tts.utils import load_model

        self.model = load_model(self.model_id)

    def synthesize(self, text: str, instruct: str | None, voice: str | None, speed: float):
        kwargs = {"text": text, "speed": speed, "lang_code": "en", "verbose": False}
        if instruct:
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

    def unload(self) -> None:
        self.model = None
        gc.collect()
        try:
            import mlx.core as mx

            clear = getattr(mx, "clear_cache", None) or mx.metal.clear_cache
            clear()
        except Exception:
            pass


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

    def synthesize(self, text, instruct, voice, speed):
        sr = 24000
        seconds = max(0.3, len(text.split()) * 0.35 / max(speed, 0.1))
        t = np.arange(int(sr * seconds)) / sr
        return (0.2 * np.sin(2 * math.pi * 220 * t)).astype(np.float32), sr

    def unload(self) -> None:
        self._loaded = False


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
    """Holds the backend and guarantees one generation at a time."""

    def __init__(self, backend):
        self.backend = backend
        self.lock = threading.Lock()  # serializes load / synthesize / unload
        self.busy = False

    def health(self) -> dict:
        return {
            "status": "ok",
            "loaded": self.backend.loaded,
            "busy": self.busy,
            "model": self.backend.model_id,
        }

    def load(self) -> float:
        with self.lock:
            start = time.perf_counter()
            self.backend.load()
            return time.perf_counter() - start

    def synthesize(self, text: str, instruct, voice, speed: float):
        with self.lock:
            self.busy = True
            try:
                self.backend.load()  # no-op if already loaded
                start = time.perf_counter()
                audio, sr = self.backend.synthesize(text, instruct, voice, speed)
                return audio, sr, time.perf_counter() - start
            finally:
                self.busy = False

    def unload(self) -> None:
        with self.lock:
            self.backend.unload()


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
                    instruct = data.get("instruct", DEFAULT_INSTRUCT)
                    audio, sr, gen = engine.synthesize(text, instruct, data.get("voice"), speed)
                    body = to_wav_bytes(audio, sr)
                    self.send_response(200)
                    self.send_header("Content-Type", "audio/wav")
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("X-Audio-Duration", f"{len(audio) / sr:.3f}")
                    self.send_header("X-Gen-Seconds", f"{gen:.3f}")
                    self.end_headers()
                    self.wfile.write(body)
                    return

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
    parser.add_argument("--preload", action="store_true", help="load the model at startup")
    parser.add_argument("--fake", action="store_true", help="sine-wave backend for testing")
    args = parser.parse_args()

    backend = FakeBackend() if args.fake else MLXBackend(args.model)
    engine = Engine(backend)
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
