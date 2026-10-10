import Foundation
import SwiftData
import SwiftUI

// MARK: - Enums

enum DocumentKind: String, Codable, CaseIterable {
    case pdf, pptx, docx

    var displayName: String {
        switch self {
        case .pdf:  "PDF"
        case .pptx: "PowerPoint"
        case .docx: "Word"
        }
    }

    var sfSymbol: String {
        switch self {
        case .pdf:  "doc.text.fill"
        case .pptx: "rectangle.on.rectangle.angled.fill"
        case .docx: "doc.richtext.fill"
        }
    }

    static func from(fileExtension ext: String) -> DocumentKind? {
        switch ext.lowercased() {
        case "pdf":           .pdf
        case "pptx", "ppt":  .pptx
        case "docx", "doc":  .docx
        default:              nil
        }
    }
}

enum GenerationStatus: String, Codable {
    case notStarted = "not_started"
    case queued
    case generating
    case complete
    case failed

    var shortLabel: String {
        switch self {
        case .notStarted:  "Not generated"
        case .queued:      "Queued"
        case .generating:  "Generating"
        case .complete:    "Ready"
        case .failed:      "Failed"
        }
    }

    var color: Color {
        switch self {
        case .notStarted:  .secondary
        case .queued:      .orange
        case .generating:  Color.accentColor
        case .complete:    .green
        case .failed:      .red
        }
    }

    var isTerminal: Bool { self == .complete || self == .failed }
    var canGenerate: Bool { self == .notStarted || self == .failed }
}

// MARK: - Model

@Model
final class VLDocument {
    var id: UUID
    var title: String
    var kindRaw: String
    var importedAt: Date
    var lastOpenedAt: Date?
    var totalPages: Int
    var currentPageIndex: Int
    var currentSentenceIndex: Int
    var generationStatusRaw: String
    var generationProgress: Int      // how many pages have audio
    var originalFileBookmark: Data?  // security-scoped bookmark for re-access

    @Relationship(deleteRule: .cascade, inverse: \DocumentPage.document)
    var pages: [DocumentPage]

    var kind: DocumentKind {
        get { DocumentKind(rawValue: kindRaw) ?? .pdf }
        set { kindRaw = newValue.rawValue }
    }

    var generationStatus: GenerationStatus {
        get { GenerationStatus(rawValue: generationStatusRaw) ?? .notStarted }
        set { generationStatusRaw = newValue.rawValue }
    }

    var progressFraction: Double {
        guard totalPages > 0 else { return 0 }
        return Double(generationProgress) / Double(totalPages)
    }

    init(title: String, kind: DocumentKind, totalPages: Int) {
        self.id = UUID()
        self.title = title
        self.kindRaw = kind.rawValue
        self.importedAt = Date()
        self.totalPages = totalPages
        self.currentPageIndex = 0
        self.currentSentenceIndex = 0
        self.generationStatusRaw = GenerationStatus.notStarted.rawValue
        self.generationProgress = 0
        self.pages = []
    }
}
