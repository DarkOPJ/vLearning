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
5. **Clean Up** (before S1): page-by-page editing of each section (page text, image text, notes,
   tables), with restore and per-page skip, so nothing unwanted reaches S1.
6. Normalize with superwhisper S1-mini, MLX 8-bit: `mlx-community/S1-mini-MLX-8bit` (Mac, via mlx-lm,
   loaded on demand and unloaded after). It's built for dictation, so it's a toggle. Thinking must be
   off, and the system prompt and control line must be exactly as on the model card. Input is up to
   ~1000 tokens, chunked at sentences.
7. Optional review after S1, sentence by sentence.
6. **Review screen**: page by page, toggle between the original page and the extracted text, edit the
   text, then "Ready to generate".
7. Generate (background), with local notifications in and out of the app.
8. Reader: my own text view with **sentence highlighting**, a toggle to the original document view,
   background playback until paused, lock-screen controls.

## TTS engine decisions
- Mac: **Breeze-TTS-2 (mlx-community/Breeze-TTS-2-mlx-8bit)** via Python mlx-audio, in `engine/`.
  Default voice: `--instruct "A calm, warm male narrator with a clear, steady pace, like an audiobook reader."`
  The user liked it.
- **Cloned voices** (`VoiceLibrary`): Settings › Voice › Cloned lists voices; add one from a .wav (or any
  audio) or a recording plus its exact text, then select, play, rename, edit text, delete. Stored as 24 kHz
  mono WAV in `~/Library/Application Support/com.darkopj.vlearning/voices/<id>.wav` + `voices.json`.
  The engine's /synthesize takes `ref_audio` (path) + `ref_text`; with a reference, no instruct is sent and
  cfg_scale isn't overridden. The engine caches the loaded reference. Clips that run far past their
  sentence are regenerated once. `VLDocument.audioVoice` holds the voice id (voice + recording + text),
  so changing the voice regenerates audio. First voice: "My Voice" (the user's 25.8 s recording).
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

## Engine setup (Mac)
- Python env: `~/Documents/xcode/vlearning-lab/.venv` (mlx-audio, mlx-lm). Path is configurable in Settings.
- `engine/server.py` is bundled into the Mac app; the app launches it on demand on port 8765 and
  calls /shutdown when work is done. Log: `~/Library/Application Support/com.darkopj.vlearning/engine.log`.
- The Mac app is **not sandboxed** (needed to run Python and read the Hugging Face cache).

## Build order
1. Engine + benchmark (done: `engine/server.py`, `engine/bench.py`). Benchmark not yet run on the Mac.
2. Xcode multiplatform project, library, design system
3. Import and extraction (PDFKit, PPTX/DOCX XML)
4. Image picker + Vision OCR
5. Sentence splitting + S1-mini
6. Review screen
7. Generation queue, background tasks, notifications
8. Reader with highlighting and playback (done: `AudioPlayer` plays the per-sentence clips with AVPlayer,
   saves the position in `currentPageIndex/currentSentenceIndex`, lock-screen controls via MediaPlayer,
   iOS background audio via `UIBackgroundModes: audio` in `vLearning/iOS-Info.plist`; `ReaderView`,
   `NowPlayingBar` at the bottom of the window)
   Original view for PPTX/DOCX: `PageRenderService` converts to PDF on the Mac (LibreOffice if installed,
   else Keynote/Pages via AppleScript), saves `rendered/<i>.jpg`, and maps pages/sentences to rendered
   pages by their words (Word reflows, so page counts can differ). Runs after import and on demand.
9. Wi-Fi sync (done: `Services/Sync/`). The Mac listens (`SyncServer`, Bonjour `_vlearning._tcp`), the
   iPhone connects (`SyncClient`) and drives a round every 15 s while open (4 s while the Mac generates
   for it). Pairing: 6-digit code in the Mac's Settings › iPhone Sync, gives the iPhone a token.
   Frames: UInt32 header len | JSON header | UInt64 body len | body (`SyncWire`). Content and reading
   position sync separately; `SyncTracker` hashes each document's snapshot after saves to know when it
   changed, and the newer change wins. Deletions sync via tombstones. Files: the whole document folder,
   by path and size; audio the winner no longer has is removed. The Mac refuses a push while it's
   generating that document. The iPhone can ask the Mac to generate (`generate` request).
   "Delete Audio" removes only a document's generated audio (toolbar and library context menu).
