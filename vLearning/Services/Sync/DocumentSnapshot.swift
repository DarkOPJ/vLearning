import Foundation
import CryptoKit

/// Everything about a document that syncs, except its reading position (synced separately, so
/// listening on one device doesn't count as editing the document).
struct DocumentSnapshot: Codable, Sendable, Equatable {
    var id: UUID
    var title: String
    var kind: String
    var importedAt: Date
    var totalPages: Int
    var generationStatus: String
    var generationProgress: Int
    var generationFraction: Double
    var audioVoice: String?
    var renderedPagePaths: [String]
    var renderedPageTexts: [String]
    var renderError: String?
    var pages: [PageSnapshot]

    /// Identifies this exact content; two devices with the same hash have the same document.
    var hash: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct PageSnapshot: Codable, Sendable, Equatable {
    var pageIndex: Int
    var extractedText: String
    var notesText: String
    var tablesText: String
    var ocrText: String
    var isLikelyScanned: Bool
    var sentences: [String]
    var imageFilePaths: [String]
    var previewImagePath: String?
    var ocrSelectedPaths: [String]
    var ocrResults: [String: String]
    var hiddenOCRPaths: [String]
    var audioFilePath: String?
    var editedBody: String?
    var editedOCR: String?
    var editedNotes: String?
    var editedTables: String?
    var isSkipped: Bool
    var preparedFrom: String?
    var preparedSentences: [String]
    var preparedWithS1: Bool
    var sentenceAudio: [String: String]
    var sentenceDurations: [String: Double]
    var renderedStart: Int?
}

/// Where listening has got to in a document.
struct PositionInfo: Codable, Sendable {
    var page: Int
    var sentence: Int
    var lastOpenedAt: Date?
    var modifiedAt: Date

    var key: String { "\(page):\(sentence)" }
}

/// One document in a device's sync listing.
struct DocSummary: Codable, Sendable {
    var id: UUID
    var title: String
    var hash: String
    var modifiedAt: Date
    var position: PositionInfo
}

struct SyncListing: Codable, Sendable {
    var docs: [DocSummary]
    var tombstones: [UUID: Date]   // deleted document → when
}

struct FileEntry: Codable, Sendable {
    var path: String   // relative to the document folder
    var size: Int64
}

/// A document's content plus the list of files in its folder.
struct DocBundle: Codable, Sendable {
    var snapshot: DocumentSnapshot
    var modifiedAt: Date
    var position: PositionInfo
    var files: [FileEntry]
}

// MARK: - Model ↔ snapshot

extension VLDocument {
    var snapshot: DocumentSnapshot {
        DocumentSnapshot(
            id: id, title: title, kind: kindRaw, importedAt: importedAt, totalPages: totalPages,
            generationStatus: generationStatusRaw, generationProgress: generationProgress,
            generationFraction: generationFraction, audioVoice: audioVoice,
            renderedPagePaths: renderedPagePaths, renderedPageTexts: renderedPageTexts,
            renderError: renderError,
            pages: pages.sorted { $0.pageIndex < $1.pageIndex }.map(\.snapshot)
        )
    }

    var positionKey: String { "\(currentPageIndex):\(currentSentenceIndex)" }

    /// Replaces this document's content with a snapshot's. The reading position isn't touched.
    func apply(_ s: DocumentSnapshot) {
        title = s.title
        kindRaw = s.kind
        importedAt = s.importedAt
        totalPages = s.totalPages
        generationStatusRaw = s.generationStatus
        generationProgress = s.generationProgress
        generationFraction = s.generationFraction
        audioVoice = s.audioVoice
        renderedPagePaths = s.renderedPagePaths
        renderedPageTexts = s.renderedPageTexts
        renderError = s.renderError

        var existing = Dictionary(pages.map { ($0.pageIndex, $0) }, uniquingKeysWith: { first, _ in first })
        var updated: [DocumentPage] = []
        for ps in s.pages {
            let page = existing.removeValue(forKey: ps.pageIndex) ?? DocumentPage(pageIndex: ps.pageIndex)
            page.apply(ps)
            updated.append(page)
        }
        // Pages the other device no longer has.
        for page in existing.values { modelContext?.delete(page) }
        pages = updated
    }
}

extension DocumentPage {
    var snapshot: PageSnapshot {
        PageSnapshot(
            pageIndex: pageIndex, extractedText: extractedText, notesText: notesText, tablesText: tablesText,
            ocrText: ocrText, isLikelyScanned: isLikelyScanned, sentences: sentences,
            imageFilePaths: imageFilePaths, previewImagePath: previewImagePath,
            ocrSelectedPaths: ocrSelectedPaths, ocrResults: ocrResults, hiddenOCRPaths: hiddenOCRPaths,
            audioFilePath: audioFilePath, editedBody: editedBody, editedOCR: editedOCR,
            editedNotes: editedNotes, editedTables: editedTables, isSkipped: isSkipped,
            preparedFrom: preparedFrom, preparedSentences: preparedSentences, preparedWithS1: preparedWithS1,
            sentenceAudio: sentenceAudio, sentenceDurations: sentenceDurations, renderedStart: renderedStart
        )
    }

    func apply(_ s: PageSnapshot) {
        pageIndex = s.pageIndex
        extractedText = s.extractedText
        notesText = s.notesText
        tablesText = s.tablesText
        ocrText = s.ocrText
        isLikelyScanned = s.isLikelyScanned
        sentences = s.sentences
        imageFilePaths = s.imageFilePaths
        previewImagePath = s.previewImagePath
        ocrSelectedPaths = s.ocrSelectedPaths
        ocrResults = s.ocrResults
        hiddenOCRPaths = s.hiddenOCRPaths
        audioFilePath = s.audioFilePath
        editedBody = s.editedBody
        editedOCR = s.editedOCR
        editedNotes = s.editedNotes
        editedTables = s.editedTables
        isSkipped = s.isSkipped
        preparedFrom = s.preparedFrom
        preparedSentences = s.preparedSentences
        preparedWithS1 = s.preparedWithS1
        sentenceAudio = s.sentenceAudio
        sentenceDurations = s.sentenceDurations
        renderedStart = s.renderedStart
    }
}
