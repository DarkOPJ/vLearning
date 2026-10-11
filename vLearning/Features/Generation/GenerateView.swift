import SwiftUI
import SwiftData

/// Starts audio generation for a document and shows its progress.
/// "Run in Background" closes the window; the job keeps going in Background Tasks.
struct GenerateView: View {
    @Bindable var document: VLDocument
    var onPrepare: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \GenerationJob.createdAt, order: .reverse) private var jobs: [GenerationJob]
    @AppStorage(GenerationQueue.voiceKey) private var voice = GenerationQueue.defaultVoice

    private var queue: GenerationQueue { .shared }
    private var job: GenerationJob? { jobs.first { $0.documentId == document.id } }
    private var activeJob: GenerationJob? { job.flatMap { $0.isActive ? $0 : nil } }
    private var missing: Int { document.sentenceCount - document.audioReadyCount }
    private var voiceChanged: Bool { document.audioVoice != nil && document.audioVoice != voice }

    var body: some View {
        VStack(spacing: 0) {
            Text("Generate Audio")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.m)
                .background(.bar)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    if !GenerationQueue.isAvailable {
                        remoteContent
                    } else if !document.isReadyToGenerate {
                        notice("Prepare the document first, so the text is cleaned up and split into sentences.",
                               systemImage: "text.badge.checkmark")
                    } else if let activeJob {
                        progress(activeJob)
                    } else {
                        summary
                    }

                    if let job, !job.isActive, let message = job.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            buttons
                .controlSize(.large)
                .padding(DS.Space.l)
                .background(.bar)
        }
        #if os(macOS)
        .frame(width: 520, height: 420)
        #endif
    }

    // MARK: - Content

    private var summary: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            LabeledContent("Sentences", value: "\(document.sentenceCount)")
            LabeledContent("Already have audio", value: "\(document.audioReadyCount)")
            Divider()
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Voice").font(.system(.caption, weight: .semibold)).foregroundStyle(.secondary)
                Text(voice).font(.callout)
                Text("Change the voice in Settings.").font(.caption).foregroundStyle(.secondary)
            }
            if voiceChanged {
                notice("The voice changed since this audio was made, so all of it will be generated again.",
                       systemImage: "info.circle")
            }
        }
    }

    private func progress(_ job: GenerationJob) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                ProgressView().controlSize(.small)
                Text(job.status == .queued ? "Waiting for other tasks to finish…" : (job.phase ?? "Working…"))
                    .font(.callout)
            }
            if job.sentencesTotal > 0 {
                ProgressView(value: job.progress)
                    .tint(Color.accentColor)
                Text("\(job.sentencesDone) of \(job.sentencesTotal) sentences")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("You can close this window. Generation continues in Background Tasks and you'll get a notification when it's done.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: DS.Space.m) {
            if let activeJob {
                Button("Stop", role: .destructive) { queue.stop(activeJob) }
                Spacer()
                Button("Run in Background") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                #if os(iOS)
                if canAskMac {
                    Button(missing == 0 ? "All Audio Ready" : "Generate on Mac") {
                        SyncClient.shared.requestGeneration(document)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(missing == 0 || macIsWorking)
                }
                #endif
                if GenerationQueue.isAvailable && !document.isReadyToGenerate {
                    Button("Prepare First") {
                        dismiss()
                        onPrepare()
                    }
                    .buttonStyle(.borderedProminent)
                } else if GenerationQueue.isAvailable {
                    Button(startLabel) { queue.enqueue(document) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(missing == 0 && !voiceChanged)
                }
            }
        }
    }

    // MARK: - iPhone: generate on the Mac

    #if os(iOS)
    private var client: SyncClient { .shared }

    private var canAskMac: Bool { client.isConnected && document.isReadyToGenerate }

    /// The Mac has the request, or is already generating this document.
    private var macIsWorking: Bool {
        if case .waiting = client.generateRequests[document.id] { return true }
        return document.generationStatus == .queued || document.generationStatus == .generating
    }
    #endif

    @ViewBuilder
    private var remoteContent: some View {
        #if os(iOS)
        if !client.isPaired {
            notice("Breeze audio is generated on your Mac. Pair with it in Settings › Mac Sync, then you can start it from here.",
                   systemImage: "desktopcomputer")
        } else if !client.isConnected {
            notice("Breeze audio is generated on your Mac. Open vLearning on your Mac, on the same Wi-Fi, to start it from here.",
                   systemImage: "wifi.exclamationmark")
        } else if !document.isReadyToGenerate {
            notice("Prepare the document first (on the Mac), so the text is cleaned up and split into sentences.",
                   systemImage: "text.badge.checkmark")
        } else {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                LabeledContent("Sentences", value: "\(document.sentenceCount)")
                LabeledContent("Already have audio", value: "\(document.audioReadyCount)")
                switch client.generateRequests[document.id] {
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                case .waiting:
                    HStack(spacing: DS.Space.m) {
                        ProgressView().controlSize(.small)
                        Text("Sending to \(client.pairedMacName ?? "your Mac")…").font(.callout)
                    }
                default:
                    if document.generationStatus == .queued || document.generationStatus == .generating {
                        HStack(spacing: DS.Space.m) {
                            ProgressView().controlSize(.small)
                            Text(document.generationStatus == .queued
                                 ? "Waiting on \(client.pairedMacName ?? "your Mac")…"
                                 : "Generating on \(client.pairedMacName ?? "your Mac")…")
                                .font(.callout)
                        }
                        ProgressView(value: document.generationFraction)
                            .tint(Color.accentColor)
                    }
                }
                Text("Your Mac generates the audio with Breeze and sends it here. Keep both apps open on the same Wi-Fi; you'll get a notification when it's ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        #else
        EmptyView()
        #endif
    }

    private var startLabel: String {
        if voiceChanged { return "Generate Again" }
        if missing == 0 { return "All Audio Ready" }
        if document.audioReadyCount > 0 { return "Generate \(missing) Remaining" }
        return "Generate"
    }
}
