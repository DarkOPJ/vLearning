import Foundation
import SwiftData

enum JobStatus: String, Codable {
    case queued, running, done, failed, cancelled
}

@Model
final class GenerationJob {
    var id: UUID
    var documentId: UUID
    var documentTitle: String
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var statusRaw: String
    var errorMessage: String?
    var pagesTotal: Int
    var pagesDone: Int
    var sentencesTotal: Int = 0
    var sentencesDone: Int = 0
    var phase: String?               // e.g. "Loading Breeze…"

    var status: JobStatus {
        get { JobStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }

    var progress: Double {
        guard sentencesTotal > 0 else { return 0 }
        return Double(sentencesDone) / Double(sentencesTotal)
    }

    var isActive: Bool { status == .queued || status == .running }

    init(documentId: UUID, documentTitle: String, pagesTotal: Int) {
        self.id = UUID()
        self.documentId = documentId
        self.documentTitle = documentTitle
        self.createdAt = Date()
        self.statusRaw = JobStatus.queued.rawValue
        self.pagesTotal = pagesTotal
        self.pagesDone = 0
    }
}
