#if os(macOS)
import Foundation
import AppKit

/// Starts the local Python engine (Breeze TTS + S1-mini) on demand and stops it when work is done,
/// so the models only use memory while something is actually running.
@MainActor
final class EngineController {

    static let shared = EngineController()

    static let pythonPathKey = "enginePythonPath"
    static let defaultPythonPath = NSString(string: "~/Documents/xcode/vlearning-lab/.venv/bin/python")
        .expandingTildeInPath

    let port = 8765
    private var process: Process?
    private var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    enum EngineError: LocalizedError {
        case pythonMissing(String)
        case scriptMissing
        case didNotStart(String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .pythonMissing(let path):
                "Python wasn't found at \(path). Set the engine's Python path in Settings."
            case .scriptMissing:
                "The engine script is missing from the app bundle."
            case .didNotStart(let log):
                "The engine didn't start.\n\(log)"
            case .server(let message):
                message
            }
        }
    }

    private init() {
        // Never leave the engine (and its models) running after the app quits.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { EngineController.shared.process?.terminate() }
        }
    }

    // MARK: - Lifecycle

    func ensureRunning() async throws {
        if await isHealthy() { return }

        let python = UserDefaults.standard.string(forKey: Self.pythonPathKey) ?? Self.defaultPythonPath
        guard FileManager.default.isExecutableFile(atPath: python) else { throw EngineError.pythonMissing(python) }
        guard let script = Bundle.main.url(forResource: "server", withExtension: "py") else {
            throw EngineError.scriptMissing
        }

        let logURL = Self.logURL
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", script.path, "--port", String(port)]
        process.standardOutput = log
        process.standardError = log
        try process.run()
        self.process = process

        // Starting Python and importing MLX takes a few seconds.
        for _ in 0..<120 {
            try await Task.sleep(for: .milliseconds(500))
            if await isHealthy() { return }
            if !process.isRunning { break }
        }
        process.terminate()
        self.process = nil
        throw EngineError.didNotStart(Self.logTail())
    }

    /// Unloads every model and stops the process.
    func shutdown() async {
        _ = try? await post("/shutdown", body: [:], timeout: 10)
        if let process, process.isRunning {
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning { process.terminate() }
        }
        process = nil
    }

    // MARK: - Calls

    /// Cleans text with S1-mini. Loads S1-mini on first use.
    func normalize(_ text: String, styling: String) async throws -> String {
        let data = try await post("/normalize", body: ["text": text, "styling": styling], timeout: 600)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let out = json["text"] as? String
        else { throw EngineError.server("Unexpected response from the engine.") }
        return out
    }

    /// The voice Breeze speaks with: a written description, or cloned from a recording.
    enum Voice {
        case described(String)
        case reference(audio: URL, transcript: String)
    }

    /// Speaks one sentence with Breeze. Returns WAV data. Loads Breeze on first use.
    func synthesize(_ text: String, voice: Voice, speed: Double = 1.0) async throws -> Data {
        var body: [String: Any] = ["text": text, "speed": speed]
        switch voice {
        case .described(let instruct):
            body["instruct"] = instruct
        case .reference(let audio, let transcript):
            // No instruct: the recording sets the voice.
            body["ref_audio"] = audio.path
            body["ref_text"] = transcript
        }
        return try await post("/synthesize", body: body, timeout: 600)
    }

    // MARK: - HTTP

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func post(_ path: String, body: [String: Any], timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw EngineError.server(message ?? "The engine returned an error.")
        }
        return data
    }

    // MARK: - Log

    static var logURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.darkopj.vlearning", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("engine.log")
    }

    private static func logTail() -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        return text.components(separatedBy: .newlines).suffix(8).joined(separator: "\n")
    }
}
#endif
