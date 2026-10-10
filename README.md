# vLearning

Read your PowerPoint, Word and PDF files aloud on Mac and iPhone, with sentence highlighting.

## Engine (Mac)

`engine/server.py` is a local TTS service around Breeze-TTS-2 (MLX). The app starts it when you
press **Generate**, sends one sentence at a time, and shuts it down when the queue is empty,
which fully frees the model's memory.

### Run the benchmark

```bash
cd ~/vLearning
source ~/vlearning-lab/.venv/bin/activate   # the env where mlx-audio is installed
python engine/bench.py
```

This starts the engine, loads Breeze, generates four sentences into `bench_out/`, prints the
time per sentence, then unloads.

### Run the engine by hand

```bash
python engine/server.py                  # http://127.0.0.1:8765
curl localhost:8765/health
curl -X POST localhost:8765/synthesize -H 'Content-Type: application/json' \
     -d '{"text":"Hello there."}' -o hello.wav
curl -X POST localhost:8765/shutdown
```

Options: `--model <repo>`, `--port`, `--preload`, `--fake` (sine wave, no model).
