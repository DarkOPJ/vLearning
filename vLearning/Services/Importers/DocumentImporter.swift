import Foundation
import SwiftData

/// Coordinates file extraction and persists the result into SwiftData.
///
/// Call `importDocument(from:into:)` from a `@MainActor` context (e.g. a SwiftUI view).
/// Heavy extraction runs on a detached task; SwiftData writes return to the main actor.
enum DocumentImporter {

    @MainActor
    static func importDocument(from url: URL, into context: ModelContext) async throws -> VLDocument {

        // Gain access to the security-scoped URL (macOS sandbox / iOS Files app).
        let didAccess = url.startAccessingSecurityScopedResource()

        // Copy to a temp file immediately so we can drop the security scope quickly.
        let ext     = url.pathExtension.lowercased()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        try FileManager.default.copyItem(at: url, to: tempURL)
        if didAccess { url.stopAccessingSecurityScopedResource() }

        guard let kind = DocumentKind.from(fileExtension: ext) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ImportError.unsupportedFormat(ext)
        }

        let title = url.deletingPathExtension().lastPathComponent

        // Insert stub immediately so the card appears in the library straight away.
        let document = VLDocument(title: title, kind: kind, totalPages: 0)
        context.insert(document)

        let documentId = document.id

        // ── Extract on a background thread ──────────────────────────────────
        let extracted: [ExtractedPage] = try await Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: tempURL) }
            return try runExtraction(from: tempURL, kind: kind)
        }.value

        // ── Persist on main actor ────────────────────────────────────────────
        let storageRoot = DocumentStorage.directory(for: documentId)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        var docPages: [DocumentPage] = []

        for ep in extracted {
            let page = DocumentPage(pageIndex: ep.index, extractedText: ep.bodyText)
            page.notesText   = ep.notesText
            page.tablesText  = ep.tablesText
            page.isLikelyScanned = ep.isLikelyScanned

            // Write image files
            var paths: [String] = []
            if !ep.imageData.isEmpty {
                let pageDir = DocumentStorage.pageDirectory(for: documentId, pageIndex: ep.index)
                try FileManager.default.createDirectory(at: pageDir, withIntermediateDirectories: true)
                for (i, imgData) in ep.imageData.enumerated() {
                    let imgURL = pageDir.appendingPathComponent("img_\(i).jpg")
                    try imgData.write(to: imgURL)
                    paths.append(imgURL.path)
                }
            }
            page.imageFilePaths = paths

            context.insert(page)
            docPages.append(page)
        }

        document.pages      = docPages
        document.totalPages = docPages.count

        return document
    }

    // MARK: - Private

    private static func runExtraction(from url: URL, kind: DocumentKind) throws -> [ExtractedPage] {
        switch kind {
        case .pdf:  try PDFExtractor.extract(from: url)
        case .pptx: try PPTXExtractor.extract(from: url)
        case .docx: try DOCXExtractor.extract(from: url)
        }
    }
}
