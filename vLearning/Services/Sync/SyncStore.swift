import Foundation
import SwiftData

/// Remembers when each document last changed on this device, so two devices can tell whose copy
/// is newer ("newer change wins"), plus which documents were deleted.
///
/// A change is noticed by hashing each document's snapshot after every save. Positions are tracked
/// separately from content. Kept in a JSON file, not SwiftData, so tracking never causes a save.
@MainActor
final class SyncTracker {

    static let shared = SyncTracker()

    struct Entry: Codable {
        var hash: String
        var modifiedAt: Date
        var posKey: String
        var posModifiedAt: Date
    }

    private struct State: Codable {
        var entries: [UUID: Entry] = [:]
        var tombstones: [UUID: Date] = [:]
    }

    private var state: State
    private var pendingRefresh: Task<Void, Never>?

    var tombstones: [UUID: Date] { state.tombstones }
    func entry(_ id: UUID) -> Entry? { state.entries[id] }

    private init() {
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: Self.fileURL))) ?? State()
        // Forget deletions after 90 days.
        let cutoff = Date.now.addingTimeInterval(-90 * 24 * 3600)
        state.tombstones = state.tombstones.filter { $0.value > cutoff }
    }

    /// Notes which documents changed since the last look.
    func refresh() {
        let docs = SyncStore.allDocuments()
        var changed = false
        for doc in docs {
            let hash = doc.snapshot.hash
            let posKey = doc.positionKey
            if var entry = state.entries[doc.id] {
                if entry.hash != hash { entry.hash = hash; entry.modifiedAt = .now; changed = true }
                if entry.posKey != posKey { entry.posKey = posKey; entry.posModifiedAt = .now; changed = true }
                state.entries[doc.id] = entry
            } else {
                state.entries[doc.id] = Entry(hash: hash, modifiedAt: doc.importedAt, posKey: posKey,
                                              posModifiedAt: doc.lastOpenedAt ?? doc.importedAt)
                changed = true
            }
        }
        let ids = Set(docs.map(\.id))
        if state.entries.keys.contains(where: { !ids.contains($0) }) {
            state.entries = state.entries.filter { ids.contains($0.key) }
            changed = true
        }
        if changed { save() }
    }

    /// Refreshes shortly after a burst of saves.
    func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    /// Records that this document's content now matches the other device's copy from `modifiedAt`.
    func markSynced(_ doc: VLDocument, modifiedAt: Date) {
        var entry = state.entries[doc.id] ?? Entry(hash: "", modifiedAt: modifiedAt, posKey: doc.positionKey,
                                                   posModifiedAt: doc.lastOpenedAt ?? doc.importedAt)
        entry.hash = doc.snapshot.hash
        entry.modifiedAt = modifiedAt
        state.entries[doc.id] = entry
        save()
    }

    func markPositionSynced(_ doc: VLDocument, modifiedAt: Date) {
        guard var entry = state.entries[doc.id] else { return }
        entry.posKey = doc.positionKey
        entry.posModifiedAt = modifiedAt
        state.entries[doc.id] = entry
        save()
    }

    func recordDeletion(_ id: UUID, at date: Date = .now) {
        state.entries[id] = nil
        state.tombstones[id] = date
        save()
    }

    func position(for doc: VLDocument) -> PositionInfo {
        PositionInfo(page: doc.currentPageIndex, sentence: doc.currentSentenceIndex,
                     lastOpenedAt: doc.lastOpenedAt,
                     modifiedAt: state.entries[doc.id]?.posModifiedAt ?? doc.lastOpenedAt ?? doc.importedAt)
    }

    // MARK: - File

    private func save() {
        try? JSONEncoder().encode(state).write(to: Self.fileURL, options: .atomic)
    }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.darkopj.vlearning", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sync-state.json")
    }
}

/// Reads and writes the library for sync, the same way on both devices.
@MainActor
enum SyncStore {

    static var context: ModelContext?

    /// Called once at launch.
    static func attach(_ context: ModelContext) {
        self.context = context
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SyncTracker.shared.scheduleRefresh() }
        }
        SyncTracker.shared.refresh()
    }

    static func allDocuments() -> [VLDocument] {
        (try? context?.fetch(FetchDescriptor<VLDocument>())) ?? []
    }

    static func document(_ id: UUID) -> VLDocument? {
        let descriptor = FetchDescriptor<VLDocument>(predicate: #Predicate { $0.id == id })
        return try? context?.fetch(descriptor).first
    }

    // MARK: - Listing and bundles

    static func listing() -> SyncListing {
        let tracker = SyncTracker.shared
        tracker.refresh()
        let docs = allDocuments().compactMap { doc -> DocSummary? in
            guard let entry = tracker.entry(doc.id) else { return nil }
            return DocSummary(id: doc.id, title: doc.title, hash: entry.hash, modifiedAt: entry.modifiedAt,
                              position: tracker.position(for: doc))
        }
        return SyncListing(docs: docs, tombstones: tracker.tombstones)
    }

    static func bundle(for doc: VLDocument) async -> DocBundle {
        let tracker = SyncTracker.shared
        tracker.refresh()
        let id = doc.id
        let files = await Task.detached { manifest(for: id) }.value
        return DocBundle(snapshot: doc.snapshot,
                         modifiedAt: tracker.entry(doc.id)?.modifiedAt ?? .now,
                         position: tracker.position(for: doc),
                         files: files)
    }

    /// Every file in a document's folder.
    nonisolated static func manifest(for id: UUID) -> [FileEntry] {
        let root = DocumentStorage.directory(for: id).standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return enumerator.compactMap { item -> FileEntry? in
            guard let url = (item as? URL)?.standardizedFileURL,
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, url.path.hasPrefix(prefix)
            else { return nil }
            return FileEntry(path: String(url.path.dropFirst(prefix.count)), size: Int64(values.fileSize ?? 0))
        }
    }

    /// Files from `remote` this device doesn't have yet (or has a different size of).
    nonisolated static func missingFiles(_ remote: [FileEntry], docId: UUID) -> [String] {
        let local = Dictionary(manifest(for: docId).map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
        return remote.filter { local[$0.path] != $0.size }.map(\.path)
    }

    /// A file path inside a document's folder, or nil if the path tries to leave it.
    nonisolated static func fileURL(docId: UUID, path: String) -> URL? {
        let parts = path.split(separator: "/")
        guard !path.isEmpty, !path.hasPrefix("/"), !parts.contains(".."), !parts.contains(".") else { return nil }
        return DocumentStorage.url(for: docId, relativePath: path)
    }

    nonisolated static func writeFile(_ data: Data, docId: UUID, path: String) throws {
        guard let url = fileURL(docId: docId, path: path) else { throw SyncError.badFrame }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Applying the other device's copy

    /// Takes the other device's content for a document (creating it if new). Its files must be written first.
    @discardableResult
    static func apply(_ bundle: DocBundle, includePosition: Bool) -> VLDocument? {
        guard let context else { return nil }
        let s = bundle.snapshot
        let doc: VLDocument
        if let existing = document(s.id) {
            doc = existing
        } else {
            doc = VLDocument(title: s.title, kind: DocumentKind(rawValue: s.kind) ?? .pdf, totalPages: s.totalPages)
            doc.id = s.id
            context.insert(doc)
        }
        doc.apply(s)
        if includePosition { applyPosition(bundle.position, to: doc) }
        removeAudioNotIn(bundle.files, docId: doc.id)
        try? context.save()

        SyncTracker.shared.markSynced(doc, modifiedAt: bundle.modifiedAt)
        if includePosition { SyncTracker.shared.markPositionSynced(doc, modifiedAt: bundle.position.modifiedAt) }
        if AudioPlayer.shared.document?.id == doc.id { AudioPlayer.shared.load(doc) }
        return doc
    }

    static func applyPosition(_ position: PositionInfo, to doc: VLDocument) {
        // Don't move the position under someone listening right now.
        if AudioPlayer.shared.document?.id == doc.id && AudioPlayer.shared.isPlaying { return }
        doc.currentPageIndex = position.page
        doc.currentSentenceIndex = position.sentence
        if let opened = position.lastOpenedAt, opened > (doc.lastOpenedAt ?? .distantPast) {
            doc.lastOpenedAt = opened
        }
        SyncTracker.shared.markPositionSynced(doc, modifiedAt: position.modifiedAt)
        if AudioPlayer.shared.document?.id == doc.id { AudioPlayer.shared.load(doc) }
    }

    /// Deletes audio clips the other device's copy no longer has (e.g. audio deleted, sentences edited).
    private static func removeAudioNotIn(_ files: [FileEntry], docId: UUID) {
        let keep = Set(files.map(\.path))
        for entry in manifest(for: docId) where entry.path.split(separator: "/").contains("audio") && !keep.contains(entry.path) {
            try? FileManager.default.removeItem(at: DocumentStorage.url(for: docId, relativePath: entry.path))
        }
    }

    // MARK: - Deleting

    /// Deletes a document and its files. With `record`, the deletion also syncs to the other device.
    static func delete(_ doc: VLDocument, record: Bool = true, at date: Date = .now) {
        if AudioPlayer.shared.document?.id == doc.id { AudioPlayer.shared.close() }
        let id = doc.id
        try? DocumentStorage.delete(id)
        context?.delete(doc)
        try? context?.save()
        if record { SyncTracker.shared.recordDeletion(id, at: date) }
    }
}
