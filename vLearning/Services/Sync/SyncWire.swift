import Foundation
import Network

/// Wire format for Mac ↔ iPhone sync over the local network.
///
/// The Mac listens (advertised with Bonjour as `_vlearning._tcp`) and the iPhone connects to it.
/// Every message is one frame, a request from the iPhone or the Mac's reply:
///
///     UInt32 header length | JSON header | UInt64 body length | body
///
/// The body is JSON for lists and documents, or raw bytes for files.
enum SyncWire {
    static let serviceType = "_vlearning._tcp"
    static let protocolVersion = 1
    static let maxHeader = 1 << 20          // 1 MB
    static let maxBody = 2 << 30            // 2 GB
}

struct SyncHeader: Codable, Sendable {
    var type: String
    var ok = true
    var error: String?
    var docId: UUID?
    var path: String?
    var token: String?
    var code: String?
    var name: String?
    var peerId: String?
    var version = SyncWire.protocolVersion

    init(_ type: String) { self.type = type }
}

struct SyncFrame: Sendable {
    var header: SyncHeader
    var body = Data()

    init(_ header: SyncHeader, body: Data = Data()) {
        self.header = header
        self.body = body
    }

    /// A reply to `type` reporting a failure.
    static func failure(_ type: String, _ message: String) -> SyncFrame {
        var header = SyncHeader(type)
        header.ok = false
        header.error = message
        return SyncFrame(header)
    }

    func decodeBody<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: body)
    }
}

enum SyncError: LocalizedError {
    case closed
    case badFrame
    case remote(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .closed:            "The connection closed."
        case .badFrame:          "Received something that isn't a vLearning sync message."
        case .remote(let text):  text
        case .notConnected:      "Not connected to your Mac."
        }
    }
}

/// An NWConnection that sends and receives whole frames, with async calls.
final class FramedConnection: @unchecked Sendable {

    let connection: NWConnection
    private let queue = DispatchQueue(label: "vlearning.sync.connection")

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// Starts the connection and waits until it's ready.
    func start(timeout: Duration = .seconds(10)) async throws {
        let watchdog = closeAfter(timeout)
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    once.run { continuation.resume(throwing: error) }
                case .cancelled:
                    once.run { continuation.resume(throwing: SyncError.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ frame: SyncFrame) async throws {
        let header = try JSONEncoder().encode(frame.header)
        var data = Data(capacity: 12 + header.count + frame.body.count)
        data.append(bigEndian: UInt32(header.count))
        data.append(header)
        data.append(bigEndian: UInt64(frame.body.count))
        data.append(frame.body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Waits for the next frame. Closes the connection if nothing complete arrives in time.
    func receive(timeout: Duration = .seconds(120)) async throws -> SyncFrame {
        let watchdog = closeAfter(timeout)
        defer { watchdog.cancel() }

        let headerLength = Int(try await receiveExactly(4).bigEndianUInt32)
        guard headerLength > 0, headerLength <= SyncWire.maxHeader else { throw SyncError.badFrame }
        let header = try JSONDecoder().decode(SyncHeader.self, from: try await receiveExactly(headerLength))
        let bodyLength = try await receiveExactly(8).bigEndianUInt64
        guard bodyLength <= UInt64(SyncWire.maxBody) else { throw SyncError.badFrame }
        return SyncFrame(header, body: try await receiveExactly(Int(bodyLength)))
    }

    /// Sends a request and waits for its reply. A reply with `ok == false` throws its error.
    func request(_ frame: SyncFrame, timeout: Duration = .seconds(120)) async throws -> SyncFrame {
        try await send(frame)
        let reply = try await receive(timeout: timeout)
        guard reply.header.ok else { throw SyncError.remote(reply.header.error ?? "The Mac refused the request.") }
        return reply
    }

    func close() {
        connection.cancel()
    }

    // MARK: - Private

    private func receiveExactly(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: SyncError.closed)
                }
            }
        }
    }

    /// Cancelling the connection makes any pending send/receive fail, which ends the wait.
    private func closeAfter(_ duration: Duration) -> Task<Void, Never> {
        Task { [connection] in
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { connection.cancel() }
        }
    }
}

/// Runs a closure at most once, from any thread.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func append(bigEndian value: UInt64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    var bigEndianUInt32: UInt32 { reduce(0) { $0 << 8 | UInt32($1) } }
    var bigEndianUInt64: UInt64 { reduce(0) { $0 << 8 | UInt64($1) } }
}
