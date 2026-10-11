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
        do {
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: url, to: tempURL)
        }

        guard let kind = DocumentKind.from(fileExtension: ext) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ImportError.unsupportedFormat(ext)
        }

        let title = url.deletingPathExtension().lastPathComponent

        // Insert stub immediately so the card appears in the library straight away.
        let document = VLDocument(title: title, kind: kind, totalPages: 0)
        context.insert(document)

        let documentId = document.id

        do {
            // ── Extract on a background thread ──────────────────────────────
            let extracted: [ExtractedPage] = try await Task.detached(priority: .userInitiated) {
                try runExtraction(from: tempURL, kind: kind)
            }.value
            guard !extracted.isEmpty else { throw ImportError.noContent }

            // ── Persist on main actor ────────────────────────────────────────
            // Stored paths are relative to the document folder (see DocumentStorage).
            let storageRoot = DocumentStorage.directory(for: documentId)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

            // Keep the original file for the "Original" view (QuickLook / PDF pages).
            try FileManager.default.moveItem(at: tempURL, to: DocumentStorage.originalURL(for: documentId, kind: kind))

            var docPages: [DocumentPage] = []

            for ep in extracted {
                let page = DocumentPage(pageIndex: ep.index, extractedText: ep.bodyText)
                page.notesText       = ep.notesText
                page.tablesText      = ep.tablesText
                page.isLikelyScanned = ep.isLikelyScanned

                let pageFolder = "pages/\(ep.index)"
                if !ep.imageData.isEmpty || ep.previewData != nil {
                    let pageDir = storageRoot.appendingPathComponent(pageFolder, isDirectory: true)
                    try FileManager.default.createDirectory(at: pageDir, withIntermediateDirectories: true)
                }

                if let preview = ep.previewData {
                    let relative = "\(pageFolder)/preview.jpg"
                    try preview.write(to: storageRoot.appendingPathComponent(relative))
                    page.previewImagePath = relative
                }

                var paths: [String] = []
                for (i, imgData) in ep.imageData.enumerated() {
                    let relative = "\(pageFolder)/img_\(i).jpg"
                    try imgData.write(to: storageRoot.appendingPathComponent(relative))
                    paths.append(relative)
                }
                page.imageFilePaths = paths

                context.insert(page)
                docPages.append(page)
            }

            document.pages      = docPages
            document.totalPages = docPages.count
        } catch {
            // Don't leave an empty card or half-written files behind.
            context.delete(document)
            try? FileManager.default.removeItem(at: tempURL)
            try? DocumentStorage.delete(documentId)
            throw error
        }

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
