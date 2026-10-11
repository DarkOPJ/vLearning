import Foundation
import AVFoundation
import CryptoKit

/// A voice Breeze can copy: a reference recording plus exactly what's said in it.
struct ClonedVoice: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var transcript: String
    var duration: Double
    var fingerprint: String   // hash of the recording, so a changed voice is noticed
    var createdAt: Date
}

/// The user's cloned voices, and which voice Breeze uses.
///
/// Each recording is kept as 24 kHz mono 16-bit WAV in the app's data folder
/// (`…/com.darkopj.vlearning/voices/<id>.wav`), whatever format it came in; names and transcripts
/// are in `voices.json` next to them. Every sentence uses the selected voice's recording.
@MainActor
@Observable
final class VoiceLibrary {

    static let shared = VoiceLibrary()

    /// Settings key: a described voice or a cloned one.
    static let modeKey = "voiceMode"
    static let selectedKey = "selectedVoiceId"

    enum Mode: String, CaseIterable, Identifiable {
        case described   // a written description (Breeze "instruct")
        case cloned      // copied from the selected recording
        var id: Self { self }

        var label: String {
            switch self {
            case .described: "Described"
            case .cloned:    "Cloned from a recording"
            }
        }
    }

    enum Failure: LocalizedError {
        case unreadable
        case tooShort(Double)
        case noTranscript

        var errorDescription: String? {
            switch self {
            case .unreadable:      "That recording couldn't be read."
            case .tooShort(let s): String(format: "The recording is only %.0f seconds. Use 5–30 seconds of one person speaking.", s)
            case .noTranscript:    "Type exactly what's said in the recording."
            }
        }
    }

    private(set) var voices: [ClonedVoice] = []

    var selectedId: UUID? {
        didSet { UserDefaults.standard.set(selectedId?.uuidString, forKey: Self.selectedKey) }
    }

    var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .described
    }

    var selected: ClonedVoice? { voices.first { $0.id == selectedId } }

    private init() {
        voices = (try? JSONDecoder().decode([ClonedVoice].self, from: Data(contentsOf: Self.indexURL))) ?? []
        selectedId = UserDefaults.standard.string(forKey: Self.selectedKey).flatMap(UUID.init)
        migrateSingleVoice()
        if selected == nil { selectedId = voices.first?.id }
    }

    // MARK: - Using a voice

    func audioURL(_ voice: ClonedVoice) -> URL {
        Self.directory.appendingPathComponent("\(voice.id.uuidString).wav")
    }

    /// Changes whenever the voice's recording or transcript changes, so audio made with an older
    /// version is regenerated (see GenerationQueue).
    func identity(_ voice: ClonedVoice) -> String {
        let text = SHA256.hash(data: Data(voice.transcript.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "voice:\(voice.id.uuidString):\(voice.fingerprint):\(text)"
    }

    // MARK: - Editing

    /// Adds a voice from any audio file (converted to the reference WAV) and its exact transcript.
    @discardableResult
    func add(name: String, audio source: URL, transcript: String) throws -> ClonedVoice {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.noTranscript }
        let id = UUID()
        let url = Self.directory.appendingPathComponent("\(id.uuidString).wav")
        let duration = try Self.convertToReference(source, to: url)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = ClonedVoice(id: id, name: trimmedName.isEmpty ? "Voice \(voices.count + 1)" : trimmedName,
                                transcript: text, duration: duration, fingerprint: Self.fingerprint(url),
                                createdAt: .now)
        voices.append(voice)
        if selected == nil { selectedId = voice.id }
        save()
        return voice
    }

    func rename(_ voice: ClonedVoice, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = voices.firstIndex(where: { $0.id == voice.id }) else { return }
        voices[i].name = trimmed
        save()
    }

    func setTranscript(_ voice: ClonedVoice, _ transcript: String) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let i = voices.firstIndex(where: { $0.id == voice.id }) else { return }
        voices[i].transcript = text
        save()
    }

    func delete(_ voice: ClonedVoice) {
        try? FileManager.default.removeItem(at: audioURL(voice))
        voices.removeAll { $0.id == voice.id }
        if selectedId == voice.id { selectedId = voices.first?.id }
        save()
    }

    // MARK: - Files

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.darkopj.vlearning/voices", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var indexURL: URL { directory.appendingPathComponent("voices.json") }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(voices).write(to: Self.indexURL, options: .atomic)
    }

    private static func fingerprint(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The earlier single-voice setup (`voice/reference.wav` + `transcript.txt`) becomes the first voice.
    private func migrateSingleVoice() {
        let fm = FileManager.default
        let old = Self.directory.deletingLastPathComponent().appendingPathComponent("voice", isDirectory: true)
        let wav = old.appendingPathComponent("reference.wav")
        guard fm.fileExists(atPath: wav.path) else { return }
        let text = (try? String(contentsOf: old.appendingPathComponent("transcript.txt"), encoding: .utf8)) ?? ""
        if (try? add(name: "My Voice", audio: wav, transcript: text)) != nil {
            try? fm.removeItem(at: old)
            if UserDefaults.standard.string(forKey: Self.modeKey) == "myVoice" {
                UserDefaults.standard.set(Mode.cloned.rawValue, forKey: Self.modeKey)
            }
        }
    }

    /// Writes `source` as 24 kHz mono 16-bit WAV. Returns its length in seconds.
    private static func convertToReference(_ source: URL, to url: URL) throws -> Double {
        let input = try AVAudioFile(forReading: source)
        let seconds = Double(input.length) / input.fileFormat.sampleRate
        guard seconds >= 3 else { throw Failure.tooShort(seconds) }

        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: input.processingFormat, to: target),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length))
        else { throw Failure.unreadable }
        try input.read(into: inBuffer)

        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * 24_000 / input.processingFormat.sampleRate) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw Failure.unreadable }
        var consumed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return inBuffer
        }
        if let error { throw error }

        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let output = try AVAudioFile(forWriting: url, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            try output.write(from: outBuffer)
        }
        return Double(outBuffer.frameLength) / 24_000
    }
}
