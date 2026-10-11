import Foundation

/// The "Original" view: page images that look like the source file, and which one shows a given
/// page or sentence. PDFs use each page's own preview; PowerPoint and Word use pages rendered on
/// the Mac, which don't always line up one-to-one with the extracted pages (Word reflows), so
/// pages and sentences are matched to rendered pages by their words.
extension VLDocument {

    /// Rendered page images in order ("" where a PDF page has no preview).
    var originalPagePaths: [String] {
        kind == .pdf
            ? pages.sorted { $0.pageIndex < $1.pageIndex }.map { $0.previewImagePath ?? "" }
            : renderedPagePaths
    }

    var hasOriginalPages: Bool { originalPagePaths.contains { !$0.isEmpty } }

    /// Rendered pages that show this page's content.
    func originalRange(for page: DocumentPage) -> Range<Int>? {
        let count = originalPagePaths.count
        if kind == .pdf {
            let sorted = pages.sorted { $0.pageIndex < $1.pageIndex }
            return sorted.firstIndex { $0.pageIndex == page.pageIndex }.map { $0..<($0 + 1) }
        }
        guard let start = page.renderedStart, start < count else { return nil }
        let nextStart = pages
            .filter { $0.pageIndex > page.pageIndex }
            .compactMap(\.renderedStart)
            .filter { $0 > start }
            .min() ?? count
        return start..<max(min(nextStart, count), start + 1)
    }

    /// The rendered page showing a sentence. A page whose content spans several rendered pages
    /// (Word reflows) matches each sentence by its words, smoothed so reading only moves forward.
    func originalIndex(for page: DocumentPage, sentence: String?) -> Int? {
        guard let range = originalRange(for: page) else { return nil }
        guard range.count > 1, kind != .pdf,
              let sentence, let position = page.sentences.firstIndex(of: sentence) else { return range.lowerBound }
        let texts = range.map { renderedPageTexts.indices.contains($0) ? renderedPageTexts[$0] : "" }
        let matches = OriginalPages.smoothedMatches(for: page.sentences, in: texts)
        return range.lowerBound + matches[position]
    }
}

enum OriginalPages {

    /// Lowercased words (letters and digits), for matching text across renderers.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// For each extracted page (in order), the rendered page where its text starts.
    /// Slides fall back to their own number; Word pages to the previous match.
    static func startIndices(pageTexts: [String], renderedTexts: [String], oneToOne: Bool) -> [Int?] {
        let rendered = renderedTexts.map { " " + $0 + " " }
        var last = 0
        return pageTexts.enumerated().map { index, text in
            let words = Self.words(text)
            var found: Int?
            for length in [8, 5, 3] where !words.isEmpty && found == nil {
                let needle = " " + words.prefix(length).joined(separator: " ") + " "
                found = rendered.indices.dropFirst(last).first { rendered[$0].contains(needle) }
            }
            if found == nil, oneToOne, index < rendered.count { found = index }
            let start = found ?? (rendered.isEmpty ? nil : last)
            if let start { last = start }
            return start
        }
    }

    /// Index of the page text that best contains a sentence. Words found on fewer pages count more,
    /// so common words don't decide it.
    static func bestMatch(for sentence: String, in pageTexts: [String]) -> Int {
        let words = Set(Self.words(sentence).filter { $0.count > 2 })
        let pageWords = pageTexts.map { Set($0.split(separator: " ").map(String.init)) }
        var best = 0, bestScore = 0.0
        for (i, set) in pageWords.enumerated() {
            let score = words.reduce(0.0) { sum, word in
                guard set.contains(word) else { return sum }
                return sum + 1 / Double(pageWords.filter { $0.contains(word) }.count)
            }
            if score > bestScore { best = i; bestScore = score }
        }
        return best
    }

    /// Best page for each sentence in order: isolated outliers removed (median of three),
    /// then never moving back a page.
    static func smoothedMatches(for sentences: [String], in pageTexts: [String]) -> [Int] {
        let raw = sentences.map { bestMatch(for: $0, in: pageTexts) }
        var result: [Int] = []
        for i in raw.indices {
            let window = raw[max(i - 1, 0)...min(i + 1, raw.count - 1)].sorted()
            result.append(max(window[window.count / 2], result.last ?? 0))
        }
        return result
    }
}
