import Foundation
import SwiftData

@Model
final class DocumentPage {
    var pageIndex: Int
    var extractedText: String        // body text from the file's text layer
    var notesText: String            // speaker notes (PPTX) or footnotes
    var tablesText: String           // stringified table content
    var ocrText: String              // text from user-selected images, in image order
    var isLikelyScanned: Bool        // PDF page with almost no selectable text
    var sentences: [String]          // split by the sentence splitter in step 5
    var imageFilePaths: [String]     // extracted images, relative to the document's storage folder
    var previewImagePath: String?    // rendered page (PDF), relative to the document's storage folder
    var selectedImageIndices: [Int]  // unused; superseded by ocrSelectedPaths
    var ocrSelectedPaths: [String] = []      // images (or the page preview) chosen for OCR
    var ocrResults: [String: String] = [:]   // relative image path → recognized text
    var hiddenOCRPaths: [String] = []        // images hidden from the OCR picker
    var audioFilePath: String?       // generated .m4a, relative to the document's storage folder

    var document: VLDocument?

    // Ordered full text the TTS engine will read: body → OCR → notes → tables
    var readableText: String {
        [extractedText, ocrText, notesText, tablesText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    var hasImages: Bool { !imageFilePaths.isEmpty }

    /// Images the user can choose to OCR: the whole page for scanned PDF pages, then embedded images.
    var ocrCandidates: [String] {
        var paths: [String] = []
        if isLikelyScanned, let preview = previewImagePath { paths.append(preview) }
        return paths + imageFilePaths
    }

    /// Rebuilds `ocrText` from the selected images' results, in on-page order.
    func rebuildOCRText() {
        ocrText = ocrCandidates
            .filter { ocrSelectedPaths.contains($0) }
            .compactMap { ocrResults[$0] }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
    var hasAudio: Bool { audioFilePath != nil }

    init(pageIndex: Int, extractedText: String = "") {
        self.pageIndex = pageIndex
        self.extractedText = extractedText
        self.notesText = ""
        self.tablesText = ""
        self.ocrText = ""
        self.isLikelyScanned = false
        self.sentences = []
        self.imageFilePaths = []
        self.selectedImageIndices = []
    }
}
