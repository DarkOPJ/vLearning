import Foundation
import SwiftData

@Model
final class DocumentPage {
    var pageIndex: Int
    var extractedText: String        // body text from the file's text layer
    var notesText: String            // speaker notes (PPTX) or footnotes
    var tablesText: String           // stringified table content
    var ocrText: String              // text from user-selected images
    var isLikelyScanned: Bool        // PDF page with almost no selectable text
    var sentences: [String]          // split by the sentence splitter in step 5
    var imageFilePaths: [String]     // extracted images, relative to the document's storage folder
    var previewImagePath: String?    // rendered page (PDF), relative to the document's storage folder
    var selectedImageIndices: [Int]  // which images the user chose for OCR
    var audioFilePath: String?       // generated .m4a, relative to the document's storage folder

    var document: VLDocument?

    // Ordered full text the TTS engine will read: body → OCR → notes → tables
    var readableText: String {
        [extractedText, ocrText, notesText, tablesText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    var hasImages: Bool { !imageFilePaths.isEmpty }
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
