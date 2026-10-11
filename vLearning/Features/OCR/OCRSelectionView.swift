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
    @State private var viewingHidden = false

    private var pages: [DocumentPage] {
        document.pages
            .filter { !$0.ocrCandidates.isEmpty }
            .sorted { $0.pageIndex < $1.pageIndex }
    }

    private func visibleCandidates(_ page: DocumentPage) -> [String] {
        page.ocrCandidates.filter { !page.hiddenOCRPaths.contains($0) }
    }

    /// Hidden images in on-page order (ignores stale paths no longer on the page).
    private func hiddenCandidates(_ page: DocumentPage) -> [String] {
        page.ocrCandidates.filter { page.hiddenOCRPaths.contains($0) }
    }

    private var visiblePages: [DocumentPage] { pages.filter { !visibleCandidates($0).isEmpty } }
    private var hiddenPages: [DocumentPage] { pages.filter { !hiddenCandidates($0).isEmpty } }
    private var allVisible: [String] { visiblePages.flatMap(visibleCandidates) }
    private var hiddenCount: Int { pages.reduce(0) { $0 + hiddenCandidates($1).count } }

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: DS.Space.m)]
    private var hadSelection: Bool { pages.contains { !$0.ocrSelectedPaths.isEmpty } }
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
                } else if viewingHidden {
                    hiddenGrid
                } else {
                    grid
                }
            }
            .navigationTitle(viewingHidden ? "Hidden Images" : "Choose Images to Read")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { if !pages.isEmpty && !viewingHidden { bottomBar } }
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
                Text("Only the images you select are read with OCR. Their text is added to the page they're on. Hide images you don't need with \(Image(systemName: "eye.slash")).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if visiblePages.isEmpty {
                    Text("All images are hidden. Use \(Image(systemName: "eye.slash")) Hidden at the top to bring them back.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, DS.Space.huge)
                }

                ForEach(visiblePages) { page in
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        Text("\(pageNoun) \(page.pageIndex + 1)").sectionHeaderStyle()
                        LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.m) {
                            ForEach(visibleCandidates(page), id: \.self) { path in
                                tile(path: path, page: page)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.xl)
        }
        .disabled(isRunning)
    }

    /// Hidden images, per page, each with its own unhide button.
    private var hiddenGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.xl) {
                if hiddenPages.isEmpty {
                    ContentUnavailableView(
                        "No Hidden Images",
                        systemImage: "eye",
                        description: Text("Images you hide will appear here.")
                    )
                    .padding(.top, DS.Space.huge)
                } else {
                    Text("Tap an image to unhide it. It goes back to its page in Choose Images to Read.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(hiddenPages) { page in
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            Text("\(pageNoun) \(page.pageIndex + 1)").sectionHeaderStyle()
                            LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.m) {
                                ForEach(hiddenCandidates(page), id: \.self) { path in
                                    hiddenTile(path: path, page: page)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.xl)
        }
    }

    private func hiddenTile(path: String, page: DocumentPage) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
        return Button {
            toggleHidden(path, on: page)
        } label: {
            Color.secondary.opacity(0.10)
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                .overlay {
                    StoredImage(url: DocumentStorage.url(for: document.id, relativePath: path),
                                maxPixelSize: 400, contentMode: .fill)
                        .opacity(0.4)
                        .saturation(0)
                }
                .clipShape(shape)
                .overlay {
                    Label("Unhide", systemImage: "eye")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, DS.Space.m)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: Capsule())
                }
                .overlay { shape.strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1) }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help("Show this image again")
        .accessibilityLabel("Unhide image")
    }

    private func tile(path: String, page: DocumentPage) -> some View {
        let isSelected = selected.contains(path)
        let isWholePage = path == page.previewImagePath
        let hasResult = page.ocrResults[path] != nil
        let shape = RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)

        return Button {
            if isSelected { selected.remove(path) } else { selected.insert(path) }
        } label: {
            // A fixed-height clear cell sizes the tile; the image only fills (and is clipped to) it.
            Color.secondary.opacity(0.10)
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .overlay {
                    StoredImage(url: DocumentStorage.url(for: document.id, relativePath: path),
                                maxPixelSize: 480, contentMode: .fill)
                }
                .clipShape(shape)
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
                .overlay {
                    shape.strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                                       lineWidth: isSelected ? 3 : 1)
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            Button {
                toggleHidden(path, on: page)
            } label: {
                Image(systemName: "eye.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(DS.Space.s)
            .help("Hide this image")
            .accessibilityLabel("Hide image")
        }
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
        if !pages.isEmpty && viewingHidden {
            ToolbarItem(placement: .primaryAction) {
                Button("Unhide All") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        for page in pages { page.hiddenOCRPaths.removeAll() }
                    }
                }
                .disabled(hiddenCount == 0)
            }
        }
        if !pages.isEmpty && !viewingHidden {
            ToolbarItem(placement: .primaryAction) {
                let allSelected = !allVisible.isEmpty && allVisible.allSatisfy(selected.contains)
                Button(allSelected ? "Select None" : "Select All") {
                    if allSelected { selected.subtract(allVisible) } else { selected.formUnion(allVisible) }
                }
                .disabled(isRunning || allVisible.isEmpty)
            }
        }
        if !pages.isEmpty {
            // Last item, so it sits at the far right of the title bar.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { viewingHidden.toggle() }
                } label: {
                    Label(viewingHidden ? "Back to Images" : "Hidden (\(hiddenCount))",
                          systemImage: viewingHidden ? "photo.on.rectangle" : "eye.slash")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(isRunning)
                .help(viewingHidden ? "Back to choosing images" : "Show hidden images")
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
                .disabled(selected.isEmpty && !hadSelection)
            }
        }
        .padding(DS.Space.l)
        .background(.bar)
    }

    private var runLabel: String {
        let pending = selected.filter { path in !pages.contains { $0.ocrResults[path] != nil } }.count
        if selected.isEmpty { return hadSelection ? "Remove Text from Images" : "Select Images to Read" }
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

    private func toggleHidden(_ path: String, on page: DocumentPage) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if let i = page.hiddenOCRPaths.firstIndex(of: path) {
                page.hiddenOCRPaths.remove(at: i)
            } else {
                page.hiddenOCRPaths.append(path)
                selected.remove(path)
            }
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
