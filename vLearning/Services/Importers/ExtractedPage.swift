import Foundation

/// Intermediate value produced by each format extractor before anything is persisted.
struct ExtractedPage: Sendable {
    let index: Int
    let bodyText: String
    let notesText: String   // speaker notes (PPTX) or footnote-style text
    let tablesText: String  // table cells joined with tabs / newlines
    let imageData: [Data]   // raw JPEG/PNG bytes; written to disk by the importer
    let isLikelyScanned: Bool  // true when a PDF page has almost no selectable text

    /// Minimum selectable-text characters before a PDF page is considered digital.
    static let scannedThreshold = 40
}

enum ImportError: LocalizedError, Sendable {
    case unsupportedFormat(String)
    case pdfLoadFailed
    case archiveOpenFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): "'\(ext)' is not a supported format."
        case .pdfLoadFailed:              "Could not open the PDF."
        case .archiveOpenFailed:          "Could not open the file archive."
        }
    }
}
