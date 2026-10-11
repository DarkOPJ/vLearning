import Foundation

enum DocumentStorage {

    // ~/Library/Application Support/com.darkopj.vlearning/documents/<uuid>/
    static func directory(for id: UUID) -> URL {
        appSupport.appendingPathComponent("documents/\(id.uuidString)", isDirectory: true)
    }

    static func pageDirectory(for docId: UUID, pageIndex: Int) -> URL {
        directory(for: docId).appendingPathComponent("pages/\(pageIndex)", isDirectory: true)
    }

    static func audioURL(for docId: UUID, pageIndex: Int) -> URL {
        directory(for: docId).appendingPathComponent("audio/page_\(pageIndex).m4a")
    }

    static func delete(_ id: UUID) throws {
        let dir = directory(for: id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    static func totalSize(for id: UUID) -> Int64 {
        let dir = directory(for: id)
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return enumerator.reduce(into: Int64(0)) { total, item in
            guard let url = item as? URL,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            else { return }
            total += Int64(size)
        }
    }

    // MARK: - Private

    private static var appSupport: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.darkopj.vlearning", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
