"""Benchmark the engine the same way the app will use it.

Starts server.py as a child process, loads the model, synthesizes a few
sentences one at a time, saves them, then shuts the engine down (full unload).

  python engine/bench.py            # real Breeze model
  python engine/bench.py --fake     # test the plumbing without a model
"""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.request

SENTENCES = [
    "The mitochondria is the powerhouse of the cell.",
    "It produces energy through cellular respiration, a process that breaks down glucose in the presence of oxygen.",
    "This energy is stored as ATP, which the cell uses to power nearly every activity.",
    "Without mitochondria, complex life as we know it would not exist.",
]


def post(base: str, path: str, payload: dict | None = None, timeout: float = 600):
    req = urllib.request.Request(
        base + path,
        data=json.dumps(payload or {}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    return urllib.request.urlopen(req, timeout=timeout)


def wait_for_health(base: str, proc: subprocess.Popen, timeout: float = 60) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            sys.exit(f"engine exited early with code {proc.returncode}")
        try:
            urllib.request.urlopen(base + "/health", timeout=1)
            return
        except (urllib.error.URLError, ConnectionError):
            time.sleep(0.2)
    sys.exit("engine did not start in time")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--fake", action="store_true")
    parser.add_argument("--out", default="bench_out")
    args = parser.parse_args()

    base = f"http://127.0.0.1:{args.port}"
    server = pathlib.Path(__file__).with_name("server.py")
    cmd = [sys.executable, str(server), "--port", str(args.port)] + (["--fake"] if args.fake else [])
    out = pathlib.Path(args.out)
    out.mkdir(exist_ok=True)

    t0 = time.perf_counter()
    proc = subprocess.Popen(cmd)
    try:
        wait_for_health(base, proc)
        load = json.load(post(base, "/load"))
        print(f"\nmodel load: {load['seconds']:.1f}s")

        total_gen = total_audio = 0.0
        for i, text in enumerate(SENTENCES, 1):
            with post(base, "/synthesize", {"text": text}) as resp:
                audio = resp.read()
                gen = float(resp.headers["X-Gen-Seconds"])
                dur = float(resp.headers["X-Audio-Duration"])
            (out / f"sentence_{i:02d}.wav").write_bytes(audio)
            total_gen += gen
            total_audio += dur
            print(f"sentence {i}: {gen:5.2f}s to make {dur:5.2f}s of audio  (x{dur / gen:.1f} realtime)")

        post(base, "/shutdown")
        proc.wait(timeout=30)
        print(f"\ntotal: {total_gen:.1f}s generating {total_audio:.1f}s of audio "
              f"(x{total_audio / total_gen:.1f} realtime)")
        print(f"end to end incl. start, load and unload: {time.perf_counter() - t0:.1f}s")
        print(f"audio saved in {out.resolve()}")
    finally:
        if proc.poll() is None:
            proc.terminate()


if __name__ == "__main__":
    main()
