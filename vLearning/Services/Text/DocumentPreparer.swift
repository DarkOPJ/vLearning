import Foundation

/// Turns a document's cleaned text into sentences ready for audio:
/// optional S1-mini cleanup (Mac), then sentence splitting. Tables are phrased locally.
@MainActor
enum DocumentPreparer {

    struct Options {
        var useS1: Bool
        var styling: String
    }

    /// S1-mini needs the local engine, which only exists on the Mac.
    static var s1Available: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Prepares every page that isn't prepared yet (or changed since). Calls `progress(done, total)`.
    /// Starts the engine only if S1-mini is used, and always shuts it down afterwards.
    static func prepare(
        _ document: VLDocument,
        options: Options,
        onlyChanged: Bool,
        progress: (Int, Int) -> Void
    ) async throws {
        let useS1 = options.useS1 && s1Available
        let pages = document.pages
            .sorted { $0.pageIndex < $1.pageIndex }
            .filter { !onlyChanged || !$0.isPrepared || $0.isPreparedStale || $0.preparedWithS1 != useS1 }

        #if os(macOS)
        if useS1 { try await EngineController.shared.ensureRunning() }
        #endif
        defer {
            #if os(macOS)
            if useS1 { Task { await EngineController.shared.shutdown() } }
            #endif
        }

        progress(0, pages.count)
        for (i, page) in pages.enumerated() {
            try Task.checkCancellation()
            let source = page.readableText
            page.sentences = page.isSkipped ? [] : try await sentences(for: page, useS1: useS1, styling: options.styling)
            page.preparedFrom = source
            page.preparedWithS1 = useS1
            progress(i + 1, pages.count)
        }
    }

    private static func sentences(for page: DocumentPage, useS1: Bool, styling: String) async throws -> [String] {
        // Prose sections in reading order; each section stays its own paragraph.
        let prose = [DocumentPage.Section.body, .ocr, .notes]
            .map { page.cleanText($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var sentences: [String] = []
        for text in prose {
            var cleaned = text
            #if os(macOS)
            if useS1 {
                cleaned = try await EngineController.shared.normalize(text, styling: styling)
            }
            #endif
            sentences += SentenceSplitter.split(cleaned)
        }
        sentences += SentenceSplitter.tableSentences(page.cleanText(.tables))
        return sentences
    }
}
