import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Settings › Voice: a described voice, or My Voice cloned from a recording. Breeze runs on the
/// Mac, so My Voice is set up there.
struct VoiceSettingsSection: View {
    @AppStorage(GenerationQueue.voiceKey) private var instruct: String = GenerationQueue.defaultVoice
    @AppStorage(MyVoice.modeKey) private var mode: MyVoice.Mode = .described

    var body: some View {
        Section {
            #if os(macOS)
            Picker("Voice", selection: $mode) {
                ForEach(MyVoice.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            #endif

            if mode == .described {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text("Voice description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $instruct)
                        .font(.body)
                        .frame(minHeight: 72)
                }
            } else {
                #if os(macOS)
                MyVoiceEditor()
                #endif
            }
        } header: {
            Text("Voice (Breeze — Mac only)")
        } footer: {
            Text(mode == .myVoice
                 ? "Breeze copies your voice from this recording for every sentence. Changing the recording or its transcript means existing audio is generated again."
                 : "Describe how the narrator should sound. Changing it means existing audio is generated again.")
                .font(.caption)
        }
    }
}

#if os(macOS)
private struct MyVoiceEditor: View {
    @State private var transcript = MyVoice.transcript
    @State private var hasRecording = MyVoice.hasRecording
    @State private var duration = MyVoice.duration
    @State private var showRecorder = false
    @State private var showImporter = false
    @State private var error: String?
    @State private var player: AVAudioPlayer?
    @State private var confirmRemove = false

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: hasRecording ? "waveform.circle.fill" : "waveform.circle")
                .font(.title2)
                .foregroundStyle(hasRecording ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(hasRecording ? "Recording" : "No recording yet")
                if let duration, hasRecording {
                    Text(String(format: "%.0f seconds", duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("5–30 seconds of you reading, in a quiet room.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if hasRecording {
                Button { togglePlay() } label: {
                    Image(systemName: player?.isPlaying == true ? "stop.fill" : "play.fill")
                }
                .help("Play the recording")
            }
            Button("Record…") { showRecorder = true }
            Button("Import…") { showImporter = true }
            if hasRecording {
                Button(role: .destructive) { confirmRemove = true } label: { Image(systemName: "trash") }
                    .help("Remove the recording and transcript")
            }
        }
        .buttonStyle(.borderless)

        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Exactly what you say in the recording")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $transcript)
                .font(.body)
                .frame(minHeight: 72)
                .onChange(of: transcript) { _, text in MyVoice.transcript = text }
            if hasRecording && transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("Add the transcript, or Breeze can't use the recording.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        }

        EmptyView()
            .sheet(isPresented: $showRecorder) {
                VoiceRecorderView(script: transcript) { url, spoken in
                    save(url, transcript: spoken)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                save(url, transcript: nil)
            }
            .confirmationDialog("Remove your voice recording?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) {
                    player?.stop()
                    MyVoice.remove()
                    refresh()
                }
            } message: {
                Text("Audio already generated with it stays until you generate again.")
            }
    }

    private func save(_ url: URL, transcript spoken: String?) {
        do {
            player?.stop()
            try MyVoice.saveRecording(from: url)
            if let spoken, !spoken.isEmpty { transcript = spoken }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        hasRecording = MyVoice.hasRecording
        duration = MyVoice.duration
        transcript = MyVoice.transcript
    }

    private func togglePlay() {
        if let player, player.isPlaying {
            player.stop()
            self.player = nil
            return
        }
        player = try? AVAudioPlayer(contentsOf: MyVoice.audioURL)
        player?.play()
    }
}

/// Records a reference clip with the Mac's microphone.
private struct VoiceRecorderView: View {
    /// Text to read aloud (starts with the current transcript, or a suggested passage).
    @State var script: String
    let onSave: (URL, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var recorder: AVAudioRecorder?
    @State private var startedAt: Date?
    @State private var recordedURL: URL?
    @State private var denied = false

    private static let suggested = "When I study, I like to read slowly and clearly, so every idea has time to land. Today we'll look at how cells turn food into energy, and why that process matters for almost everything the body does."

    init(script: String, onSave: @escaping (URL, String) -> Void) {
        _script = State(initialValue: script.isEmpty ? Self.suggested : script)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text("Record My Voice").font(.headline)
            Text("Read this aloud at your normal pace. Edit it first if you like; it's saved as the transcript, so say exactly these words.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $script)
                .font(.title3)
                .frame(minHeight: 110)
                .disabled(recorder != nil)

            HStack(spacing: DS.Space.m) {
                if recorder != nil {
                    Button("Stop", systemImage: "stop.circle.fill") { stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text(elapsed).monospacedDigit().foregroundStyle(.secondary)
                    }
                } else {
                    Button(recordedURL == nil ? "Start Recording" : "Record Again", systemImage: "record.circle") { start() }
                }
                Spacer()
                if denied {
                    Text("Allow the microphone in System Settings › Privacy & Security.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                Button("Cancel") { recorder?.stop(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use Recording") {
                    if let recordedURL { onSave(recordedURL, script) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(recordedURL == nil || recorder != nil)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 520)
    }

    private var elapsed: String {
        let s = Int(Date.now.timeIntervalSince(startedAt ?? .now))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func start() {
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { denied = true; return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("my-voice-\(UUID().uuidString).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
            guard let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.record() else { return }
            self.recorder = recorder
            startedAt = .now
            recordedURL = nil
        }
    }

    private func stop() {
        recorder?.stop()
        recordedURL = recorder?.url
        recorder = nil
    }
}
#endif
