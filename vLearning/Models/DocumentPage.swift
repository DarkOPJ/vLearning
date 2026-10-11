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
    var sentences: [String]          // what will be read, one TTS request each
    var imageFilePaths: [String]     // extracted images, relative to the document's storage folder
    var previewImagePath: String?    // rendered page (PDF), relative to the document's storage folder
    var selectedImageIndices: [Int]  // unused; superseded by ocrSelectedPaths
    var ocrSelectedPaths: [String] = []      // images (or the page preview) chosen for OCR
    var ocrResults: [String: String] = [:]   // relative image path → recognized text
    var hiddenOCRPaths: [String] = []        // images hidden from the OCR picker
    var audioFilePath: String?       // generated .m4a, relative to the document's storage folder

    // Clean Up edits (before S1-mini). nil = use the original section text unchanged.
    var editedBody: String?
    var editedOCR: String?
    var editedNotes: String?
    var editedTables: String?
    var isSkipped: Bool = false      // user chose not to read this page at all

    // Prepared for reading (S1-mini + sentence splitting).
    var preparedFrom: String?        // readableText the sentences were made from
    var preparedSentences: [String] = []   // sentences as Prepare produced them (before review edits)
    var preparedWithS1: Bool = false

    var document: VLDocument?

    /// The four text sections of a page, in the order they're read.
    enum Section: String, CaseIterable, Identifiable {
        case body, ocr, notes, tables
        var id: Self { self }

        var title: String {
            switch self {
            case .body:   "Page text"
            case .ocr:    "Text from images"
            case .notes:  "Speaker notes"
            case .tables: "Table"
            }
        }
    }

    func originalText(_ section: Section) -> String {
        switch section {
        case .body:   extractedText
        case .ocr:    ocrText
        case .notes:  notesText
        case .tables: tablesText
        }
    }

    func editedText(_ section: Section) -> String? {
        switch section {
        case .body:   editedBody
        case .ocr:    editedOCR
        case .notes:  editedNotes
        case .tables: editedTables
        }
    }

    /// Stores an edit; setting the original text back (or nil) clears the edit.
    func setEditedText(_ text: String?, for section: Section) {
        let value = text == originalText(section) ? nil : text
        switch section {
        case .body:   editedBody = value
        case .ocr:    editedOCR = value
        case .notes:  editedNotes = value
        case .tables: editedTables = value
        }
    }

    /// The section's text after Clean Up edits.
    func cleanText(_ section: Section) -> String {
        editedText(section) ?? originalText(section)
    }

    func isEdited(_ section: Section) -> Bool { editedText(section) != nil }
    var hasEdits: Bool { Section.allCases.contains(where: isEdited) }

    /// Sections that have text either originally or after editing.
    var presentSections: [Section] {
        Section.allCases.filter { !originalText($0).isEmpty || isEdited($0) }
    }

    /// Ordered full text that goes on to S1-mini and the TTS engine: body → OCR → notes → tables.
    var readableText: String {
        guard !isSkipped else { return "" }
        return Section.allCases
            .map { cleanText($0).trimmingCharacters(in: .whitespacesAndNewlines) }
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
    /// If the OCR text changes, Clean Up edits to it no longer apply and are dropped.
    func rebuildOCRText() {
        let previous = ocrText
        ocrText = ocrCandidates
            .filter { ocrSelectedPaths.contains($0) }
            .compactMap { ocrResults[$0] }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if ocrText != previous { editedOCR = nil }
    }

    var hasAudio: Bool { audioFilePath != nil }

    var isPrepared: Bool { preparedFrom != nil }
    /// Sentences were edited after Prepare (review after S1).
    var sentencesEdited: Bool { !preparedSentences.isEmpty && sentences != preparedSentences }
    /// Prepared, but the text was edited (or OCR changed) afterwards.
    var isPreparedStale: Bool { preparedFrom.map { $0 != readableText } ?? false }

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
