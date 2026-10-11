import SwiftUI
import SwiftData

/// Lets the user pick which images (and scanned pages) to OCR, then runs Vision on just those.
/// Text from each selected image is added to its own page; deselected images lose their OCR text.
struct OCRSelectionView: View {
    @Bindable var document: VLDocument
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<String> = []
    @State private var running: Task<Void, Never>?
    @State private var done = 0
    @State private var total = 0
    @State private var failures = 0

    private var pages: [DocumentPage] {
        document.pages
            .filter { !$0.ocrCandidates.isEmpty }
            .sorted { $0.pageIndex < $1.pageIndex }
    }

    private var allCandidates: [String] { pages.flatMap(\.ocrCandidates) }
    private var pageNoun: String { document.kind == .pptx ? "Slide" : "Page" }
    private var isRunning: Bool { running != nil }

    var body: some View {
        NavigationStack {
            Group {
                if pages.isEmpty {
                    ContentUnavailableView(
                        "No Images",
                        systemImage: "photo.on.rectangle",
                        description: Text("This document has no images or scanned pages to read.")
                    )
                } else {
                    grid
                }
            }
            .navigationTitle("Choose Images to Read")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { if !pages.isEmpty { bottomBar } }
        }
        #if os(macOS)
        .frame(minWidth: 680, minHeight: 560)
        #endif
        .interactiveDismissDisabled(isRunning)
        .onAppear(perform: loadSelection)
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.xl) {
                Text("Only the images you select are read with OCR. Their text is added to the page they're on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(pages) { page in
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text("\(pageNoun) \(page.pageIndex + 1)").sectionHeaderStyle()
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: DS.Space.m)],
                                  spacing: DS.Space.m) {
                            ForEach(page.ocrCandidates, id: \.self) { path in
                                tile(path: path, page: page)
                            }
                        }
                    }
                }
            }
            .padding(DS.Space.xl)
        }
        .disabled(isRunning)
    }

    private func tile(path: String, page: DocumentPage) -> some View {
        let isSelected = selected.contains(path)
        let isWholePage = path == page.previewImagePath
        let hasResult = page.ocrResults[path] != nil

        return Button {
            if isSelected { selected.remove(path) } else { selected.insert(path) }
        } label: {
            StoredImage(url: DocumentStorage.url(for: document.id, relativePath: path),
                        maxPixelSize: 400, contentMode: .fill)
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : .black.opacity(0.35))
                        .padding(DS.Space.s)
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: DS.Space.xs) {
                        if isWholePage { chip("Whole page", systemImage: "doc.viewfinder") }
                        if hasResult { chip("Read", systemImage: "text.viewfinder") }
                    }
                    .padding(DS.Space.s)
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isWholePage ? "Whole page" : "Image")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func chip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(.caption2, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
    }

    // MARK: - Bars

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(isRunning ? "Stop" : "Cancel") {
                if isRunning { running?.cancel() } else { dismiss() }
            }
        }
        if !pages.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button(selected.count == allCandidates.count ? "Select None" : "Select All") {
                    selected = selected.count == allCandidates.count ? [] : Set(allCandidates)
                }
                .disabled(isRunning)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: DS.Space.s) {
            if isRunning {
                ProgressView(value: Double(done), total: Double(max(total, 1))) {
                    Text("Reading image \(min(done + 1, total)) of \(total)…")
                        .font(.callout)
                }
                .tint(Color.accentColor)
            } else {
                if failures > 0 {
                    Label("\(failures) image\(failures == 1 ? "" : "s") couldn't be read.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Button(action: run) {
                    Text(runLabel)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(DS.Space.l)
        .background(.bar)
    }

    private var runLabel: String {
        let pending = selected.filter { path in !pages.contains { $0.ocrResults[path] != nil } }.count
        if selected.isEmpty { return "Continue Without OCR" }
        if pending == 0 { return "Save Selection" }
        return "Read \(pending) Image\(pending == 1 ? "" : "s")"
    }

    // MARK: - Actions

    private func loadSelection() {
        var initial = Set(pages.flatMap(\.ocrSelectedPaths))
        // First visit: suggest scanned pages, since they have no text otherwise.
        if initial.isEmpty, pages.allSatisfy({ $0.ocrResults.isEmpty }) {
            initial = Set(pages.filter(\.isLikelyScanned).compactMap(\.previewImagePath))
        }
        selected = initial
    }

    private func run() {
        // Images that are selected but not read yet.
        let work: [(page: DocumentPage, path: String)] = pages.flatMap { page in
            page.ocrCandidates
                .filter { selected.contains($0) && page.ocrResults[$0] == nil }
                .map { (page, $0) }
        }
        let docId = document.id
        done = 0
        total = work.count
        failures = 0

        running = Task {
            for item in work {
                if Task.isCancelled { break }
                let url = DocumentStorage.url(for: docId, relativePath: item.path)
                let text = await Task.detached(priority: .userInitiated) {
                    try? TextRecognizer.recognize(imageAt: url)
                }.value
                if let text { item.page.ocrResults[item.path] = text } else { failures += 1 }
                done += 1
            }
            applySelection()
            running = nil
            if !Task.isCancelled && failures == 0 { dismiss() }
        }
    }

    /// Saves the selection on every page and rebuilds each page's OCR text from it.
    private func applySelection() {
        for page in pages {
            page.ocrSelectedPaths = page.ocrCandidates.filter { selected.contains($0) }
            page.rebuildOCRText()
        }
    }
}
