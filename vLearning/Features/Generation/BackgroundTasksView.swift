import SwiftUI
import SwiftData

/// Every generation job: running, waiting in the queue, and finished. One runs at a time.
struct BackgroundTasksView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \GenerationJob.createdAt, order: .reverse) private var jobs: [GenerationJob]

    private var queue: GenerationQueue { .shared }

    var body: some View {
        VStack(spacing: 0) {
            Text("Background Tasks")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.m)
                .background(.bar)
            Divider()

            if jobs.isEmpty {
                ContentUnavailableView("No Tasks", systemImage: "waveform",
                                       description: Text("Audio you generate shows up here while it works."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(jobs) { job in
                        JobRow(job: job,
                               onStop: { queue.stop(job) },
                               onRemove: { queue.remove(job) })
                    }
                }
                #if os(macOS)
                .listStyle(.inset)
                #endif
            }

            Divider()
            HStack {
                Button("Clear Finished") { queue.clearFinished() }
                    .disabled(!jobs.contains { !$0.isActive })
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(DS.Space.l)
            .background(.bar)
        }
        #if os(macOS)
        .frame(width: 560, height: 480)
        #endif
    }
}

private struct JobRow: View {
    let job: GenerationJob
    let onStop: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            icon
                .frame(width: 22)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(job.documentTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(job.status == .failed ? .red : .secondary)
                    .lineLimit(2)
                if job.isActive && job.sentencesTotal > 0 {
                    ProgressView(value: job.progress)
                        .tint(Color.accentColor)
                }
            }
            Spacer(minLength: DS.Space.s)
            if job.isActive {
                Button("Stop", role: .destructive, action: onStop)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from the list")
            }
        }
        .padding(.vertical, DS.Space.xs)
    }

    @ViewBuilder
    private var icon: some View {
        switch job.status {
        case .running:   ProgressView().controlSize(.small)
        case .queued:    Image(systemName: "clock").foregroundStyle(.orange)
        case .done:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        switch job.status {
        case .running:   "\(job.phase ?? "Working…")  ·  \(job.sentencesDone)/\(job.sentencesTotal)"
        case .queued:    "Waiting in the queue"
        case .done:      "Done · \(job.sentencesTotal) sentences" + (job.completedAt.map { " · \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
        case .failed:    job.errorMessage ?? "Failed"
        case .cancelled: "Stopped · \(job.sentencesDone) of \(job.sentencesTotal) sentences have audio"
        }
    }
}
