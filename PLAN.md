# vLearning plan and decisions

Handoff notes so any new Claude session (local or cloud) has the full context.

## Goal
Native SwiftUI app for **macOS (MacBook Pro M4)** and **iOS (iPhone 14 Pro Max)** that reads PPTX, DOCX
and PDF (digital, scanned, hybrid) aloud, with sentence highlighting. English only.

## Pipeline
1. Import a document (either device).
2. Extract per page: text, images, speaker notes, tables (in page order). Skip headers and footers.
3. Image picker: the user chooses which images to OCR. Only those get OCR'd (Apple Vision), and their
   text is inserted into that page.
4. Split into sentences, even when full stops are missing (NaturalLanguage plus heuristics).
5. Normalize with superwhisper S1-mini (~0.6B; built for dictation, so it's a toggle; test that it
   doesn't reword document text).
6. **Review screen**: page by page, toggle between the original page and the extracted text, edit the
   text, then "Ready to generate".
7. Generate (background), with local notifications in and out of the app.
8. Reader: my own text view with **sentence highlighting**, a toggle to the original document view,
   background playback until paused, lock-screen controls.

## TTS engine decisions
- Mac: **Breeze-TTS-2 (mlx-community/Breeze-TTS-2-mlx-8bit)** via Python mlx-audio, in `engine/`.
  Default voice: `--instruct "A calm, warm male narrator with a clear, steady pace, like an audiobook reader."`
  The user liked it. Voice cloning comes later.
- The engine **does not start with the app**. It starts on "Ready to generate". The UI shows a spinner,
  and cancel moves the job to a Background Tasks list. Tasks queue, with **one generation at a time**.
  When the queue is empty, the engine shuts down and fully unloads the model.
- iPhone: Apple's on-device voices (AVSpeechSynthesizer) standalone. On the same Wi-Fi, it sends jobs
  to the Mac engine for Breeze audio.
- KittenTTS 2 was dropped (1.7B, needs PyTorch).
- Later: mlx-community/Qwen3-VL-4B-Instruct-8bit as an OCR engine, with the same load/unload pattern.

## Free Apple developer account (the user will never pay)
- The iOS app expires every 7 days; reinstall from Xcode (data is kept).
- No CloudKit: sync goes Mac <-> iPhone over the local Wi-Fi (Bonjour/Network.framework).
- No push notifications: local notifications only.
- No background GPU or higher memory limit entitlements on iOS.

## Other features decided
Speed 0.5–2x, voice picker, resume position, tap a sentence to jump there, skip by sentence or page,
sleep timer, library with progress, M4A export, storage management. Modern minimal design with light
and dark mode.

## Build order
1. Engine + benchmark (done: `engine/server.py`, `engine/bench.py`). Benchmark not yet run on the Mac.
2. Xcode multiplatform project, library, design system
3. Import and extraction (PDFKit, PPTX/DOCX XML)
4. Image picker + Vision OCR
5. Sentence splitting + S1-mini
6. Review screen
7. Generation queue, background tasks, notifications
8. Reader with highlighting and playback
9. Wi-Fi sync
