import Foundation

/// Intermediate value produced by each format extractor before anything is persisted.
struct ExtractedPage: Sendable {
    let index: Int
    let bodyText: String
    let notesText: String   // speaker notes (PPTX) or footnote-style text
    let tablesText: String  // one row per line, cells separated by tabs
    let imageData: [Data]   // embedded images (JPEG/PNG bytes), candidates for OCR
    let previewData: Data?  // rendered page (PDF only), shown as the "original" page
    let isLikelyScanned: Bool  // true when a PDF page has almost no selectable text

    init(index: Int, bodyText: String, notesText: String = "", tablesText: String = "",
         imageData: [Data] = [], previewData: Data? = nil, isLikelyScanned: Bool = false) {
        self.index = index
        self.bodyText = bodyText
        self.notesText = notesText
        self.tablesText = tablesText
        self.imageData = imageData
        self.previewData = previewData
        self.isLikelyScanned = isLikelyScanned
    }

    /// Minimum selectable-text characters before a PDF page is considered digital.
    static let scannedThreshold = 40
}

enum ImportError: LocalizedError, Sendable {
    case unsupportedFormat(String)
    case pdfLoadFailed
    case archiveOpenFailed
    case noContent

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): "'\(ext)' is not a supported format."
        case .pdfLoadFailed:              "Could not open the PDF."
        case .archiveOpenFailed:          "Could not open the file archive."
        case .noContent:                  "No pages were found in this file."
        }
    }
}
