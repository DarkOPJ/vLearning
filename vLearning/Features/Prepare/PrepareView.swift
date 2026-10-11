import SwiftUI
import SwiftData

/// Runs S1-mini cleanup (optional, Mac) and sentence splitting over the document.
struct PrepareView: View {
    @Bindable var document: VLDocument
    var onFinished: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @AppStorage("normalizerEnabled") private var useS1 = true
    @AppStorage("normalizerStyling") private var styling = "formal"

    @State private var task: Task<Void, Never>?
    @State private var done = 0
    @State private var total = 0
    @State private var phase: String?
    @State private var errorMessage: String?

    private var isRunning: Bool { task != nil }
    private var pages: [DocumentPage] { document.pages }
    private var readyCount: Int { pages.filter { $0.isPrepared && !$0.isPreparedStale }.count }
    private var changedCount: Int { pages.filter { !$0.isPrepared || $0.isPreparedStale }.count }
    private var pageNoun: String { document.kind == .pptx ? "slide" : "page" }

    var body: some View {
        VStack(spacing: 0) {
            Text("Prepare for Reading")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.m)
                .background(.bar)
            Divider()

            Form {
                Section {
                    Toggle("Clean up with S1-mini", isOn: $useS1)
                        .disabled(!DocumentPreparer.s1Available || isRunning)
                    if useS1 && DocumentPreparer.s1Available {
                        Picker("Style", selection: $styling) {
                            Text("Formal").tag("formal")
                            Text("Semi-formal").tag("semi-formal")
                        }
                        .disabled(isRunning)
                    }
                } footer: {
                    Text(DocumentPreparer.s1Available
                         ? "S1-mini adds punctuation and fixes broken lines, so headings, bullets and OCR text read naturally. It runs on this Mac and unloads when it's done."
                         : "S1-mini cleanup runs on your Mac. Here the text is split into sentences as it is.")
                }

                Section {
                    LabeledContent("Ready", value: "\(readyCount) of \(pages.count) \(pageNoun)s")
                    if readyCount > 0 && changedCount > 0 {
                        LabeledContent("Changed or new", value: "\(changedCount)")
                    }
                }

                if isRunning {
                    Section {
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            Text(phase ?? "Working…").font(.callout)
                            if total > 0 {
                                ProgressView(value: Double(done), total: Double(total))
                                    .tint(Color.accentColor)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: DS.Space.m) {
                Button(isRunning ? "Stop" : "Cancel") {
                    if isRunning { task?.cancel() } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if readyCount > 0 && !isRunning {
                    Button("Prepare All Again") { start(onlyChanged: false) }
                }
                Button(primaryLabel) { start(onlyChanged: readyCount > 0) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning || (readyCount > 0 && changedCount == 0))
            }
            .controlSize(.large)
            .padding(DS.Space.l)
            .background(.bar)
        }
        #if os(macOS)
        .frame(width: 520, height: 520)
        #endif
        .interactiveDismissDisabled(isRunning)
    }

    private var primaryLabel: String {
        if readyCount == 0 { return "Prepare" }
        if changedCount == 0 { return "All Ready" }
        return "Prepare \(changedCount) Changed"
    }

    private func start(onlyChanged: Bool) {
        errorMessage = nil
        done = 0
        total = 0
        let options = DocumentPreparer.Options(useS1: useS1, styling: styling)
        phase = options.useS1 && DocumentPreparer.s1Available ? "Starting S1-mini…" : "Splitting sentences…"

        task = Task {
            do {
                try await DocumentPreparer.prepare(document, options: options, onlyChanged: onlyChanged) { d, t in
                    done = d
                    total = t
                    phase = "Preparing \(pageNoun) \(min(d + 1, t)) of \(t)…"
                }
                task = nil
                onFinished()
                dismiss()
            } catch is CancellationError {
                task = nil
                phase = nil
            } catch {
                task = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}
