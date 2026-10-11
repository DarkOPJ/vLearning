import Foundation
import AVFoundation
import CryptoKit

/// The user's own voice for Breeze: one reference recording and its exact transcript.
///
/// Kept in the app's data folder (`…/com.darkopj.vlearning/voice/`) so every sentence of every
/// document is generated from the same reference. Stored as 24 kHz mono 16-bit WAV, whatever
/// format it was recorded or imported in.
enum MyVoice {

    /// Settings key: which voice Breeze uses.
    static let modeKey = "voiceMode"

    enum Mode: String, CaseIterable, Identifiable {
        case described   // a written description (Breeze "instruct")
        case myVoice     // cloned from the reference recording
        var id: Self { self }

        var label: String {
            switch self {
            case .described: "Described voice"
            case .myVoice:   "My Voice"
            }
        }
    }

    static var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .described
    }

    enum Failure: LocalizedError {
        case unreadable
        case tooShort(Double)
        case noTranscript

        var errorDescription: String? {
            switch self {
            case .unreadable:         "That recording couldn't be read."
            case .tooShort(let s):    String(format: "The recording is only %.0f seconds. Use 5–30 seconds of you speaking.", s)
            case .noTranscript:       "Type exactly what you say in the recording."
            }
        }
    }

    // MARK: - Files

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.darkopj.vlearning/voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var audioURL: URL { directory.appendingPathComponent("reference.wav") }
    static var transcriptURL: URL { directory.appendingPathComponent("transcript.txt") }

    static var hasRecording: Bool { FileManager.default.fileExists(atPath: audioURL.path) }

    static var transcript: String {
        get { (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? "" }
        set { try? newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .write(to: transcriptURL, atomically: true, encoding: .utf8) }
    }

    /// The recording and transcript, if both are set.
    static var reference: (url: URL, transcript: String)? {
        let text = transcript
        guard hasRecording, !text.isEmpty else { return nil }
        return (audioURL, text)
    }

    /// Changes whenever the recording or transcript changes, so audio made from an older
    /// reference is regenerated (see GenerationQueue).
    static var identity: String? {
        guard let reference, let audio = try? Data(contentsOf: reference.url) else { return nil }
        var hasher = SHA256()
        hasher.update(data: audio)
        hasher.update(data: Data(reference.transcript.utf8))
        return "my-voice:" + hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static var duration: Double? {
        guard let file = try? AVAudioFile(forReading: audioURL) else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    // MARK: - Saving

    /// Converts any audio file to the reference WAV. The transcript is saved separately.
    static func saveRecording(from source: URL) throws {
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

        let temp = directory.appendingPathComponent("reference-new.wav")
        try? FileManager.default.removeItem(at: temp)
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let output = try AVAudioFile(forWriting: temp, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            try output.write(from: outBuffer)
        }
        _ = try FileManager.default.replaceItemAt(audioURL, withItemAt: temp)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: audioURL)
        try? FileManager.default.removeItem(at: transcriptURL)
        if mode == .myVoice { UserDefaults.standard.set(Mode.described.rawValue, forKey: modeKey) }
    }
}
