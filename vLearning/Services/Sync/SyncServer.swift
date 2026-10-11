#if os(macOS)
import Foundation
import Network

/// The Mac's side of Wi-Fi sync. Advertises itself on the local network and answers the iPhone.
///
/// The iPhone pairs once with a 6-digit code shown in Settings and gets a token; every later
/// connection must present it. The iPhone drives each sync round; the Mac only answers.
@MainActor
@Observable
final class SyncServer {

    static let shared = SyncServer()

    struct PairedDevice: Codable, Identifiable, Hashable {
        var id: String { token }
        var token: String
        var name: String
        var pairedAt: Date
        var lastSyncAt: Date?
    }

    static let enabledKey = "syncEnabled"

    private(set) var isRunning = false
    private(set) var pairCode = ""
    private(set) var pairedDevices: [PairedDevice] = []
    private(set) var connectedDevices: Set<String> = []   // device names
    private(set) var listenerError: String?

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            newValue ? start() : stop()
        }
    }

    let macId: String
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: FramedConnection] = [:]
    private var wrongCodeCount = 0
    private let queue = DispatchQueue(label: "vlearning.sync.listener")

    private init() {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "syncMacId") {
            macId = id
        } else {
            macId = UUID().uuidString
            defaults.set(macId, forKey: "syncMacId")
        }
        if let data = defaults.data(forKey: "syncPairedDevices"),
           let devices = try? JSONDecoder().decode([PairedDevice].self, from: data) {
            pairedDevices = devices
        }
        pairCode = defaults.string(forKey: "syncPairCode") ?? ""
        if pairCode.isEmpty { newPairCode() }
    }

    var macName: String { Host.current().localizedName ?? "Mac" }

    // MARK: - Listening

    func startIfEnabled() {
        if isEnabled { start() }
    }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: macName, type: SyncWire.serviceType,
                                                  txtRecord: NWTXTRecord(["id": macId]))
            listener.newConnectionHandler = { connection in
                Task { @MainActor in SyncServer.shared.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                Task { @MainActor in SyncServer.shared.listenerChanged(state) }
            }
            listener.start(queue: queue)
            self.listener = listener
            listenerError = nil
        } catch {
            listenerError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.close() }
        connections = [:]
        connectedDevices = []
        isRunning = false
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            listenerError = nil
        case .failed(let error):
            isRunning = false
            listenerError = error.localizedDescription
            listener?.cancel()
            listener = nil
            // Try again shortly (e.g. after the network changes).
            Task {
                try? await Task.sleep(for: .seconds(5))
                if isEnabled { start() }
            }
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    // MARK: - Pairing

    func newPairCode() {
        pairCode = String(format: "%06d", Int.random(in: 0...999_999))
        UserDefaults.standard.set(pairCode, forKey: "syncPairCode")
        wrongCodeCount = 0
    }

    func unpair(_ device: PairedDevice) {
        pairedDevices.removeAll { $0.token == device.token }
        savePairedDevices()
    }

    private func savePairedDevices() {
        UserDefaults.standard.set(try? JSONEncoder().encode(pairedDevices), forKey: "syncPairedDevices")
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let framed = FramedConnection(connection)
        connections[ObjectIdentifier(framed)] = framed
        Task { await serve(framed) }
    }

    private func serve(_ connection: FramedConnection) async {
        var session = Session()
        do {
            try await connection.start()
            while true {
                // An idle iPhone checks in every few seconds; drop it after 5 quiet minutes.
                let request = try await connection.receive(timeout: .seconds(300))
                let reply: SyncFrame
                do {
                    reply = try await handle(request, session: &session)
                } catch {
                    reply = .failure(request.header.type, error.localizedDescription)
                }
                try await connection.send(reply)
            }
        } catch {
            // Connection closed.
        }
        connection.close()
        connections[ObjectIdentifier(connection)] = nil
        if let name = session.device?.name { connectedDevices.remove(name) }
    }

    /// What one connection has told us so far.
    private struct Session {
        var device: PairedDevice?
        var pending: [UUID: DocBundle] = [:]   // pushed documents waiting for their files
    }

    private func handle(_ request: SyncFrame, session: inout Session) async throws -> SyncFrame {
        let header = request.header
        var reply = SyncHeader(header.type)

        switch header.type {
        case "pair":
            guard let code = header.code, code == pairCode else {
                wrongCodeCount += 1
                if wrongCodeCount >= 5 { newPairCode() }
                return .failure("pair", "That code doesn't match the one on your Mac.")
            }
            let device = PairedDevice(token: UUID().uuidString + UUID().uuidString, name: header.name ?? "iPhone",
                                      pairedAt: .now)
            pairedDevices.removeAll { $0.name == device.name }
            pairedDevices.append(device)
            savePairedDevices()
            newPairCode()   // each code works once
            session.device = device
            connectedDevices.insert(device.name)
            reply.token = device.token
            reply.peerId = macId
            reply.name = macName
            return SyncFrame(reply)

        case "hello":
            guard let device = pairedDevices.first(where: { $0.token == header.token }) else {
                return .failure("hello", "unpaired")
            }
            session.device = device
            connectedDevices.insert(device.name)
            reply.peerId = macId
            reply.name = macName
            return SyncFrame(reply)

        default:
            break
        }

        guard let device = session.device else { return .failure(header.type, "unpaired") }

        switch header.type {
        case "list":
            if let i = pairedDevices.firstIndex(where: { $0.token == device.token }) {
                pairedDevices[i].lastSyncAt = .now
                savePairedDevices()
            }
            return SyncFrame(reply, body: try JSONEncoder().encode(SyncStore.listing()))

        case "get":
            guard let id = header.docId, let doc = SyncStore.document(id) else {
                return .failure("get", "That document isn't on the Mac.")
            }
            return SyncFrame(reply, body: try JSONEncoder().encode(await SyncStore.bundle(for: doc)))

        case "file":
            guard let id = header.docId, let path = header.path, let url = SyncStore.fileURL(docId: id, path: path) else {
                return .failure("file", "Bad file path.")
            }
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            return SyncFrame(reply, body: data)

        case "put":
            let bundle = try request.decodeBody(DocBundle.self)
            let id = bundle.snapshot.id
            if GenerationQueue.shared.activeJob(for: id) != nil {
                return .failure("put", "busy")   // being generated: the Mac's copy wins for now
            }
            session.pending[id] = bundle
            let missing = await Task.detached { SyncStore.missingFiles(bundle.files, docId: id) }.value
            return SyncFrame(reply, body: try JSONEncoder().encode(missing))

        case "upload":
            guard let id = header.docId, let path = header.path, session.pending[id] != nil else {
                return .failure("upload", "Send the document first.")
            }
            let body = request.body
            try await Task.detached { try SyncStore.writeFile(body, docId: id, path: path) }.value
            return SyncFrame(reply)

        case "commit":
            guard let id = header.docId, let bundle = session.pending.removeValue(forKey: id) else {
                return .failure("commit", "Nothing to save.")
            }
            guard GenerationQueue.shared.activeJob(for: id) == nil else { return .failure("commit", "busy") }
            let isNew = SyncStore.document(id) == nil
            if let doc = SyncStore.apply(bundle, includePosition: isNew) {
                // Nothing is generating it here, whatever the iPhone's copy says.
                if doc.generationStatus == .queued || doc.generationStatus == .generating {
                    doc.generationStatus = doc.hasAllAudio ? .complete : .notStarted
                }
                if isNew && PageRenderService.shared.needsRender(doc) { PageRenderService.shared.render(doc) }
            }
            return SyncFrame(reply)

        case "position":
            guard let id = header.docId, let doc = SyncStore.document(id) else { return SyncFrame(reply) }
            let position = try request.decodeBody(PositionInfo.self)
            SyncTracker.shared.refresh()
            let local = SyncTracker.shared.position(for: doc)
            if position.modifiedAt > local.modifiedAt { SyncStore.applyPosition(position, to: doc) }
            return SyncFrame(reply)

        case "delete":
            guard let id = header.docId else { return SyncFrame(reply) }
            let deletedAt = try request.decodeBody(Date.self)
            if let doc = SyncStore.document(id), GenerationQueue.shared.activeJob(for: id) == nil {
                SyncTracker.shared.refresh()
                let modified = SyncTracker.shared.entry(id)?.modifiedAt ?? .distantPast
                if modified <= deletedAt { SyncStore.delete(doc, at: deletedAt) }
            }
            return SyncFrame(reply)

        case "generate":
            guard let id = header.docId, let doc = SyncStore.document(id) else {
                return .failure("generate", "That document isn't on the Mac yet. Try again in a moment.")
            }
            guard doc.isReadyToGenerate else {
                return .failure("generate", "Prepare this document first, so it's split into sentences.")
            }
            GenerationQueue.shared.enqueue(doc)
            return SyncFrame(reply)

        default:
            return .failure(header.type, "Unknown request. Update vLearning on both devices.")
        }
    }
}
#endif
