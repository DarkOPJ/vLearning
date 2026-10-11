#if os(iOS)
import Foundation
import Network
import UIKit

/// The iPhone's side of Wi-Fi sync. Finds the paired Mac on the local network and, while the app
/// is open, syncs every few seconds: documents, edits, audio and the reading position, both ways.
/// The newer change wins.
@MainActor
@Observable
final class SyncClient {

    static let shared = SyncClient()

    struct Peer: Identifiable, Hashable {
        let id: String          // the Mac's sync id
        let name: String
        let endpoint: NWEndpoint
    }

    enum Status: Equatable {
        case off              // not paired
        case searching        // paired, Mac not found
        case connecting
        case connected        // idle between rounds
        case syncing(String)
        case failed(String)

        var label: String {
            switch self {
            case .off:                 "Not paired"
            case .searching:           "Looking for your Mac…"
            case .connecting:          "Connecting…"
            case .connected:           "Connected"
            case .syncing(let what):   what
            case .failed(let message): message
            }
        }
    }

    /// The Mac's answer to "generate this document".
    enum GenerateRequest: Equatable {
        case waiting
        case sent
        case failed(String)
    }

    private(set) var discovered: [Peer] = []
    private(set) var status: Status = .off
    private(set) var lastSync: Date?
    private(set) var generateRequests: [UUID: GenerateRequest] = [:]

    private(set) var pairedMacId: String? = UserDefaults.standard.string(forKey: "syncPairedMacId")
    private(set) var pairedMacName: String? = UserDefaults.standard.string(forKey: "syncPairedMacName")
    private var token: String? = UserDefaults.standard.string(forKey: "syncToken")

    var isPaired: Bool { token != nil && pairedMacId != nil }
    var isConnected: Bool { connection != nil }

    private var browser: NWBrowser?
    private var connection: FramedConnection?
    private var loop: Task<Void, Never>?
    private var nap: Task<Void, Never>?
    private var isActive = false

    private init() {}

    // MARK: - App lifecycle

    /// The app came to the foreground: look for the Mac and sync.
    func activate() {
        isActive = true
        startBrowsing()
        if isPaired && status == .off { status = .searching }
        connectIfPossible()
    }

    /// The app went to the background: finish with one last round, then let go.
    func deactivate() {
        isActive = false
        browser?.cancel()
        browser = nil
        guard let loop else { return }
        // Wake the loop: it runs one more round, sees the app is in the background and stops.
        endBackgroundWork()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "vLearning sync") {
            // Out of background time: stop now (called on the main thread).
            MainActor.assumeIsolated { SyncClient.shared.endBackgroundWork(disconnecting: true) }
        }
        nap?.cancel()
        Task {
            await loop.value
            endBackgroundWork()
        }
    }

    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    private func endBackgroundWork(disconnecting: Bool = false) {
        if disconnecting { disconnect() }
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Pairing

    func pair(with peer: Peer, code: String) async throws {
        let connection = FramedConnection(NWConnection(to: peer.endpoint, using: .tcp))
        defer { connection.close() }
        try await connection.start()
        var header = SyncHeader("pair")
        header.code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        header.name = UIDevice.current.name
        let reply = try await connection.request(SyncFrame(header))
        guard let token = reply.header.token else { throw SyncError.remote("The Mac didn't send a pairing token.") }

        self.token = token
        pairedMacId = reply.header.peerId ?? peer.id
        pairedMacName = reply.header.name ?? peer.name
        let defaults = UserDefaults.standard
        defaults.set(token, forKey: "syncToken")
        defaults.set(pairedMacId, forKey: "syncPairedMacId")
        defaults.set(pairedMacName, forKey: "syncPairedMacName")

        await Notifier.shared.requestPermission()
        status = .searching
        connectIfPossible()
    }

    func unpair() {
        disconnect()
        token = nil
        pairedMacId = nil
        pairedMacName = nil
        for key in ["syncToken", "syncPairedMacId", "syncPairedMacName"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        status = .off
    }

    // MARK: - Requests from the UI

    /// Sync right away instead of waiting for the next round.
    func syncNow() {
        if connection == nil { connectIfPossible() } else { nap?.cancel() }
    }

    /// Asks the Mac to generate a document's audio with Breeze. Syncs the document first.
    func requestGeneration(_ doc: VLDocument) {
        generateRequests[doc.id] = .waiting
        syncNow()
    }

    // MARK: - Finding the Mac

    private func startBrowsing() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: SyncWire.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { results, _ in
            let peers: [Peer] = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var id = name
                if case .bonjour(let txt) = result.metadata, let value = txt["id"] { id = value }
                return Peer(id: id, name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in SyncClient.shared.peersChanged(peers) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func peersChanged(_ peers: [Peer]) {
        discovered = peers.sorted { $0.name < $1.name }
        connectIfPossible()
    }

    private func connectIfPossible() {
        guard isActive, isPaired, connection == nil, loop == nil,
              let peer = discovered.first(where: { $0.id == pairedMacId }) else { return }
        loop = Task { await run(peer) }
    }

    // MARK: - Sync loop

    private func run(_ peer: Peer) async {
        status = .connecting
        let connection = FramedConnection(NWConnection(to: peer.endpoint, using: .tcp))
        do {
            try await connection.start()
            var hello = SyncHeader("hello")
            hello.token = token
            let reply = try await connection.request(SyncFrame(hello))
            if let name = reply.header.name, name != pairedMacName {
                pairedMacName = name
                UserDefaults.standard.set(name, forKey: "syncPairedMacName")
            }
            self.connection = connection
            status = .connected

            while !Task.isCancelled {
                try await round(connection)
                status = .connected
                if !isActive { break }
                // Check often while the Mac is making audio for this phone, otherwise every 15 s.
                let busy = SyncStore.allDocuments().contains {
                    $0.generationStatus == .queued || $0.generationStatus == .generating
                }
                await sleep(busy ? .seconds(4) : .seconds(15))
            }
        } catch {
            if case SyncError.remote(let message) = error, message == "unpaired" {
                unpair()
                status = .failed("Your Mac no longer recognises this iPhone. Pair again.")
            } else if !Task.isCancelled {
                status = .failed("Lost the connection to \(pairedMacName ?? "your Mac").")
            }
        }
        connection.close()
        if self.connection === connection { self.connection = nil }
        loop = nil

        // Try again in a little while, if still wanted.
        if isActive && isPaired && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(8))
            if status != .off { status = .searching }
            connectIfPossible()
        }
    }

    private func sleep(_ duration: Duration) async {
        let nap = Task { _ = try? await Task.sleep(for: duration) }
        self.nap = nap
        await nap.value
        self.nap = nil
    }

    private func disconnect() {
        loop?.cancel()
        nap?.cancel()
        connection?.close()
        connection = nil
        loop = nil
        status = isPaired ? .searching : .off
    }

    // MARK: - One round

    /// Compares both libraries and brings each document up to date in the right direction.
    private func round(_ connection: FramedConnection) async throws {
        let tracker = SyncTracker.shared
        tracker.refresh()

        let listing = try await connection.request(SyncFrame(SyncHeader("list"))).decodeBody(SyncListing.self)
        let remoteIds = Set(listing.docs.map(\.id))

        // Deleted on the Mac.
        for (id, deletedAt) in listing.tombstones {
            guard let doc = SyncStore.document(id) else { continue }
            if (tracker.entry(id)?.modifiedAt ?? .distantPast) <= deletedAt {
                SyncStore.delete(doc, at: deletedAt)
            }
        }
        // Deleted here.
        for (id, deletedAt) in tracker.tombstones where remoteIds.contains(id) {
            var header = SyncHeader("delete")
            header.docId = id
            _ = try await connection.request(SyncFrame(header, body: try JSONEncoder().encode(deletedAt)))
        }

        // On the Mac: pull, push or just sync the position.
        for remote in listing.docs where tracker.tombstones[remote.id] == nil {
            guard SyncStore.document(remote.id) != nil, let entry = tracker.entry(remote.id) else {
                try await pull(remote.id, title: remote.title, isNew: true, over: connection)
                continue
            }
            if entry.hash != remote.hash {
                if entry.modifiedAt > remote.modifiedAt {
                    try await push(remote.id, over: connection)
                } else {
                    try await pull(remote.id, title: remote.title, isNew: false, over: connection)
                }
            }
            try await syncPosition(remote, over: connection)
        }

        // Only here: send to the Mac.
        for doc in SyncStore.allDocuments() where !remoteIds.contains(doc.id) && listing.tombstones[doc.id] == nil {
            try await push(doc.id, over: connection)
        }

        try await sendGenerateRequests(over: connection)
        lastSync = .now
    }

    private func pull(_ id: UUID, title: String, isNew: Bool, over connection: FramedConnection) async throws {
        status = .syncing("Getting “\(title)”…")
        var header = SyncHeader("get")
        header.docId = id
        let bundle = try await connection.request(SyncFrame(header)).decodeBody(DocBundle.self)

        let missing = await Task.detached { SyncStore.missingFiles(bundle.files, docId: id) }.value
        for (i, path) in missing.enumerated() {
            if missing.count > 3 { status = .syncing("Getting “\(title)” (\(i + 1) of \(missing.count) files)…") }
            var fileHeader = SyncHeader("file")
            fileHeader.docId = id
            fileHeader.path = path
            let data = try await connection.request(SyncFrame(fileHeader), timeout: .seconds(300)).body
            try await Task.detached { try SyncStore.writeFile(data, docId: id, path: path) }.value
        }

        let before = SyncStore.document(id)
        let wasReady = before?.hasAllAudio ?? false
        let hadAudioRequest = generateRequests[id] == .sent
        guard let doc = SyncStore.apply(bundle, includePosition: isNew) else { return }

        if doc.hasAllAudio && !wasReady && doc.generationStatus == .complete && (hadAudioRequest || !isNew) {
            Notifier.shared.post(title: "Audio ready", body: "\(doc.title) is ready to listen to on your iPhone.")
            generateRequests[id] = nil
        }
    }

    private func push(_ id: UUID, over connection: FramedConnection) async throws {
        guard let doc = SyncStore.document(id) else { return }
        status = .syncing("Sending “\(doc.title)”…")
        let bundle = await SyncStore.bundle(for: doc)

        var header = SyncHeader("put")
        header.docId = id
        let missing: [String]
        do {
            missing = try await connection.request(SyncFrame(header, body: try JSONEncoder().encode(bundle)))
                .decodeBody([String].self)
        } catch SyncError.remote("busy") {
            return   // the Mac is generating it; its copy comes back when done
        }

        for (i, path) in missing.enumerated() {
            if missing.count > 3 { status = .syncing("Sending “\(doc.title)” (\(i + 1) of \(missing.count) files)…") }
            guard let url = SyncStore.fileURL(docId: id, path: path) else { continue }
            guard let data = try? await Task.detached(operation: { try Data(contentsOf: url) }).value else { continue }
            var upload = SyncHeader("upload")
            upload.docId = id
            upload.path = path
            _ = try await connection.request(SyncFrame(upload, body: data), timeout: .seconds(300))
        }

        var commit = SyncHeader("commit")
        commit.docId = id
        do {
            _ = try await connection.request(SyncFrame(commit))
        } catch SyncError.remote("busy") {
            return
        }
        // The Mac now has exactly this copy.
        SyncTracker.shared.markSynced(doc, modifiedAt: bundle.modifiedAt)
    }

    private func syncPosition(_ remote: DocSummary, over connection: FramedConnection) async throws {
        guard let doc = SyncStore.document(remote.id) else { return }
        let local = SyncTracker.shared.position(for: doc)
        guard local.key != remote.position.key else { return }
        if local.modifiedAt > remote.position.modifiedAt {
            var header = SyncHeader("position")
            header.docId = remote.id
            _ = try await connection.request(SyncFrame(header, body: try JSONEncoder().encode(local)))
        } else {
            SyncStore.applyPosition(remote.position, to: doc)
        }
    }

    private func sendGenerateRequests(over connection: FramedConnection) async throws {
        for (id, request) in generateRequests where request == .waiting {
            var header = SyncHeader("generate")
            header.docId = id
            do {
                _ = try await connection.request(SyncFrame(header))
                generateRequests[id] = .sent
                if let doc = SyncStore.document(id) { doc.generationStatus = .queued }
            } catch SyncError.remote(let message) {
                generateRequests[id] = .failed(message)
            }
        }
    }
}
#endif
