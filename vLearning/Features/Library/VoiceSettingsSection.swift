import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Settings › Voice: a described voice, or one cloned from a recording in the voice library.
/// Breeze runs on the Mac, so voices are managed there.
struct VoiceSettingsSection: View {
    @AppStorage(GenerationQueue.voiceKey) private var instruct: String = GenerationQueue.defaultVoice
    @AppStorage(VoiceLibrary.modeKey) private var mode: VoiceLibrary.Mode = .described

    var body: some View {
        Section {
            #if os(macOS)
            Picker("Voice", selection: $mode) {
                ForEach(VoiceLibrary.Mode.allCases) { Text($0.label).tag($0) }
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
                VoiceLibraryList()
                #endif
            }
        } header: {
            Text("Voice (Breeze — Mac only)")
        } footer: {
            Text(mode == .cloned
                 ? "Breeze copies the selected voice from its recording for every sentence. Choosing another voice, or changing a voice's text, means existing audio is generated again."
                 : "Describe how the narrator should sound. Changing it means existing audio is generated again.")
                .font(.caption)
        }
    }
}

#if os(macOS)
/// The cloned voices: pick one, play, rename, edit its text, delete, or add a new one.
private struct VoiceLibraryList: View {
    @State private var library = VoiceLibrary.shared
    @State private var player = ClipPlayer()
    @State private var showAdd = false
    @State private var renaming: ClonedVoice?
    @State private var newName = ""
    @State private var editingText: ClonedVoice?
    @State private var deleting: ClonedVoice?

    var body: some View {
        if library.voices.isEmpty {
            Text("No voices yet. Add a recording of someone speaking (5–30 seconds, one speaker) and exactly what they say.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        ForEach(library.voices) { voice in
            row(voice)
        }

        Button("Add Voice…", systemImage: "plus") { showAdd = true }
            .buttonStyle(.borderless)
            .sheet(isPresented: $showAdd) { AddVoiceView() }
            .alert("Rename Voice", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                   presenting: renaming) { voice in
                TextField("Name", text: $newName)
                Button("Rename") { library.rename(voice, to: newName) }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $editingText) { voice in
                TranscriptEditor(voice: voice)
            }
            .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { voice in
                Button("Delete Voice", role: .destructive) {
                    player.stop()
                    library.delete(voice)
                }
            } message: { _ in
                Text("The recording is removed. Audio already generated with it stays until you generate again.")
            }
    }

    private func row(_ voice: ClonedVoice) -> some View {
        let isSelected = library.selectedId == voice.id
        return HStack(spacing: DS.Space.m) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name).fontWeight(isSelected ? .semibold : .regular)
                Text(String(format: "%.0f s · ", voice.duration) + voice.transcript)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                player.toggle(library.audioURL(voice))
            } label: {
                Image(systemName: player.playing == library.audioURL(voice) ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Play the recording")
            Menu {
                Button("Use This Voice", systemImage: "checkmark") { library.selectedId = voice.id }
                    .disabled(isSelected)
                Button("Rename…", systemImage: "pencil") {
                    newName = voice.name
                    renaming = voice
                }
                Button("Edit Text…", systemImage: "text.quote") { editingText = voice }
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive) { deleting = voice }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture { library.selectedId = voice.id }
    }
}

/// Adds a voice: a .wav (or any audio file) or a new recording, with exactly what's said in it.
private struct AddVoiceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var transcript = ""
    @State private var source: URL?
    @State private var sourceDuration: Double?
    @State private var showImporter = false
    @State private var recorder = VoiceRecorder()
    @State private var player = ClipPlayer()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text("Add Voice").font(.headline)

            TextField("Name (e.g. My Voice)", text: $name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Recording").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: DS.Space.m) {
                    if recorder.isRecording {
                        Button("Stop", systemImage: "stop.circle.fill") {
                            if let url = recorder.stop() { use(url) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            Text(recorder.elapsed).monospacedDigit().foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Choose WAV…", systemImage: "folder") { showImporter = true }
                        Button("Record", systemImage: "record.circle") {
                            Task { error = await recorder.start() }
                        }
                        if let source {
                            Button { player.toggle(source) } label: {
                                Image(systemName: player.playing == source ? "stop.fill" : "play.fill")
                            }
                            .buttonStyle(.borderless)
                            Text(source.lastPathComponent.hasPrefix("recording-") ? "New recording" : source.lastPathComponent)
                                .lineLimit(1)
                            if let sourceDuration {
                                Text(String(format: "%.0f s", sourceDuration)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Exactly what's said in the recording").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $transcript)
                    .font(.body)
                    .frame(minHeight: 100)
                    .overlay(alignment: .topLeading) {
                        if transcript.isEmpty {
                            Text("If you're recording now, type the text first and read it aloud.")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel") {
                    _ = recorder.stop()
                    player.stop()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add Voice") { add() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(source == nil || recorder.isRecording
                              || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 540)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.wav, .audio]) { result in
            guard case .success(let url) = result else { return }
            // Copy it in now, while we have access to the file.
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            do {
                try FileManager.default.copyItem(at: url, to: copy)
                if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
                use(copy)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func use(_ url: URL) {
        source = url
        sourceDuration = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.fileFormat.sampleRate }
        error = nil
    }

    private func add() {
        guard let source else { return }
        do {
            player.stop()
            try VoiceLibrary.shared.add(name: name, audio: source, transcript: transcript)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Edits the exact text of a voice's recording.
private struct TranscriptEditor: View {
    let voice: ClonedVoice
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text("Text of “\(voice.name)”").font(.headline)
            Text("Exactly what's said in the recording, word for word.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    VoiceLibrary.shared.setTranscript(voice, text)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 520)
        .onAppear { text = voice.transcript }
    }
}

/// Plays one clip at a time.
@MainActor
@Observable
private final class ClipPlayer {
    private(set) var playing: URL?
    private var player: AVAudioPlayer?
    private var endTask: Task<Void, Never>?

    func toggle(_ url: URL) {
        if playing == url { stop(); return }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        player.play()
        playing = url
        endTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(player.duration + 0.2))
            guard !Task.isCancelled else { return }
            self?.playing = nil
        }
    }

    func stop() {
        endTask?.cancel()
        player?.stop()
        player = nil
        playing = nil
    }
}

/// Records from the Mac's microphone to a temporary WAV.
@MainActor
@Observable
private final class VoiceRecorder {
    private var recorder: AVAudioRecorder?
    private var startedAt: Date?

    var isRecording: Bool { recorder != nil }

    var elapsed: String {
        let s = Int(Date.now.timeIntervalSince(startedAt ?? .now))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Returns an error message if recording couldn't start.
    func start() async -> String? {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            return "Allow vLearning to use the microphone in System Settings › Privacy & Security › Microphone."
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.record() else {
            return "Recording couldn't start."
        }
        self.recorder = recorder
        startedAt = .now
        return nil
    }

    func stop() -> URL? {
        guard let recorder else { return nil }
        recorder.stop()
        self.recorder = nil
        return recorder.url
    }
}
#endif
