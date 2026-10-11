import Foundation
import AVFoundation

/// Converts the engine's WAV output to compact AAC (.m4a) files for storage and playback.
enum AudioEncoder {

    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "The generated audio couldn't be read." }
    }

    /// Writes `wav` as AAC to `url`. Returns the duration in seconds.
    static func writeM4A(fromWAV wav: Data, to url: URL) throws -> Double {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try wav.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let input = try AVAudioFile(forReading: temp)
        let format = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.length))
        else { throw Failure.unreadable }
        try input.read(into: buffer)

        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 64_000,
        ]
        // Scope the writer so the file is finalized before we return.
        do {
            let output = try AVAudioFile(forWriting: url, settings: settings,
                                         commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            try output.write(from: buffer)
        }
        return Double(input.length) / format.sampleRate
    }
}
