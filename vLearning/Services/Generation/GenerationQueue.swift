import Foundation
import SwiftData
import CryptoKit

/// Runs audio generation jobs one at a time, in the order they were queued.
///
/// Each sentence becomes its own audio clip, keyed by the sentence text, so a job can stop and
/// resume, and edited sentences are the only ones regenerated. Breeze is loaded by the first job
/// and fully unloaded (the engine stops) once the queue is empty.
@MainActor
@Observable
final class GenerationQueue {

    static let shared = GenerationQueue()

    static let voiceKey = "breezeInstruct"
    static let defaultVoice = "A calm, warm male narrator with a clear, steady pace, like an audiobook reader."

    /// Breeze runs through the Mac's local engine.
    static var isAvailable: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private var context: ModelContext?
    private var worker: Task<Void, Never>?
    private var current: (id: UUID, task: Task<Void, Never>)?

    /// Whether any job is queued or running.
    private(set) var isBusy = false

    private init() {}

    /// Called once at launch. Jobs interrupted by quitting the app go back in the queue and resume.
    func attach(_ context: ModelContext) {
        self.context = context
        for job in fetchJobs() where job.status == .running {
            job.status = .queued
            job.phase = nil
        }
        startIfIdle()
    }

    // MARK: - Queue

    /// Queues audio generation for a document (no-op if it's already queued or running).
    @discardableResult
    func enqueue(_ document: VLDocument) -> GenerationJob? {
        guard let context else { return nil }
        if let existing = activeJob(for: document.id) { return existing }

        let job = GenerationJob(documentId: document.id, documentTitle: document.title,
                                pagesTotal: document.readPages.count)
        job.sentencesTotal = document.sentenceCount
        job.sentencesDone = document.audioReadyCount
        context.insert(job)
        document.generationStatus = .queued

        Task { await Notifier.shared.requestPermission() }
        startIfIdle()
        return job
    }

    func stop(_ job: GenerationJob) {
        if current?.id == job.id {
            current?.task.cancel()
        } else if job.status == .queued {
            job.status = .cancelled
            job.completedAt = .now
            if let doc = document(job.documentId) { doc.generationStatus = statusAfterStop(doc) }
        }
    }

    func remove(_ job: GenerationJob) {
        guard !job.isActive else { return }
        context?.delete(job)
    }

    func clearFinished() {
        for job in fetchJobs() where !job.isActive { context?.delete(job) }
    }

    func activeJob(for documentId: UUID) -> GenerationJob? {
        fetchJobs().first { $0.documentId == documentId && $0.isActive }
    }

    func latestJob(for documentId: UUID) -> GenerationJob? {
        fetchJobs().first { $0.documentId == documentId }
    }

    // MARK: - Worker

    private func startIfIdle() {
        guard worker == nil, nextQueuedJob() != nil else { return }
        isBusy = true
        worker = Task { await runQueue() }
    }

    private func runQueue() async {
        #if os(macOS)
        // Keep generating when the app is in the background or the Mac is idle.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Generating audio")
        #endif

        while let job = nextQueuedJob() {
            let task = Task { await run(job) }
            current = (job.id, task)
            await task.value
            current = nil
        }

        #if os(macOS)
        // Queue is empty: unload Breeze completely.
        await EngineController.shared.shutdown()
        ProcessInfo.processInfo.endActivity(activity)
        #endif
        worker = nil
        isBusy = false
    }

    private func run(_ job: GenerationJob) async {
        guard let doc = document(job.documentId) else {
            finish(job, status: .failed, error: "The document was deleted.")
            return
        }

        job.status = .running
        job.startedAt = .now
        job.errorMessage = nil
        doc.generationStatus = .generating

        do {
            #if os(macOS)
            let voice = UserDefaults.standard.string(forKey: Self.voiceKey) ?? Self.defaultVoice
            if doc.audioVoice != voice {
                discardAllAudio(doc)  // a different voice: everything is regenerated
                doc.audioVoice = voice
            }

            // Each distinct sentence on a page needs one clip.
            let work: [(page: DocumentPage, sentence: String)] = doc.readPages.flatMap { page in
                Array(NSOrderedSet(array: page.sentencesMissingAudio)).compactMap { $0 as? String }.map { (page, $0) }
            }
            job.sentencesTotal = doc.sentenceCount
            job.sentencesDone = doc.audioReadyCount
            doc.generationFraction = job.progress

            if !work.isEmpty {
                job.phase = "Starting the engine…"
                try await EngineController.shared.ensureRunning()
                job.phase = "Loading Breeze…"

                for item in work {
                    try Task.checkCancellation()
                    let wav = try await EngineController.shared.synthesize(item.sentence, instruct: voice)
                    try Task.checkCancellation()

                    let relative = "pages/\(item.page.pageIndex)/audio/\(Self.clipName(item.sentence)).m4a"
                    let url = DocumentStorage.url(for: doc.id, relativePath: relative)
                    let duration = try await Task.detached(priority: .userInitiated) {
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                                withIntermediateDirectories: true)
                        return try AudioEncoder.writeM4A(fromWAV: wav, to: url)
                    }.value

                    item.page.sentenceAudio[item.sentence] = relative
                    item.page.sentenceDurations[item.sentence] = duration
                    job.sentencesDone = doc.audioReadyCount
                    doc.generationFraction = job.progress
                    job.phase = "Generating sentence \(min(job.sentencesDone + 1, job.sentencesTotal)) of \(job.sentencesTotal)…"
                }
            }

            removeUnusedAudio(doc)
            finish(job, status: .done)
            doc.generationStatus = .complete
            doc.generationFraction = 1
            Notifier.shared.post(title: "Audio ready", body: "\(doc.title) is ready to listen to.")
            #else
            throw GenerationError.unavailable
            #endif
        } catch is CancellationError {
            finish(job, status: .cancelled)
            doc.generationStatus = statusAfterStop(doc)
        } catch {
            finish(job, status: .failed, error: error.localizedDescription)
            doc.generationStatus = .failed
            Notifier.shared.post(title: "Audio generation failed", body: "\(doc.title): \(error.localizedDescription)")
        }
    }

    private func finish(_ job: GenerationJob, status: JobStatus, error: String? = nil) {
        job.status = status
        job.errorMessage = error
        job.completedAt = .now
        job.phase = nil
    }

    private func statusAfterStop(_ doc: VLDocument) -> GenerationStatus {
        doc.hasAllAudio ? .complete : .notStarted
    }

    // MARK: - Audio files

    /// Stable file name for a sentence's clip.
    static func clipName(_ sentence: String) -> String {
        SHA256.hash(data: Data(sentence.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private func discardAllAudio(_ doc: VLDocument) {
        for page in doc.pages {
            for path in page.sentenceAudio.values {
                try? FileManager.default.removeItem(at: DocumentStorage.url(for: doc.id, relativePath: path))
            }
            page.sentenceAudio = [:]
            page.sentenceDurations = [:]
        }
    }

    /// Deletes clips for sentences that were edited away.
    private func removeUnusedAudio(_ doc: VLDocument) {
        for page in doc.pages {
            let keep = Set(page.sentences)
            for (sentence, path) in page.sentenceAudio where !keep.contains(sentence) {
                try? FileManager.default.removeItem(at: DocumentStorage.url(for: doc.id, relativePath: path))
                page.sentenceAudio[sentence] = nil
                page.sentenceDurations[sentence] = nil
            }
        }
    }

    // MARK: - Fetching

    private func fetchJobs() -> [GenerationJob] {
        let descriptor = FetchDescriptor<GenerationJob>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context?.fetch(descriptor)) ?? []
    }

    private func nextQueuedJob() -> GenerationJob? {
        fetchJobs().reversed().first { $0.status == .queued }
    }

    private func document(_ id: UUID) -> VLDocument? {
        let descriptor = FetchDescriptor<VLDocument>(predicate: #Predicate { $0.id == id })
        return try? context?.fetch(descriptor).first
    }
}

enum GenerationError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Breeze audio is generated on your Mac." }
}
