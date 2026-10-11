import SwiftUI
import SwiftData
import QuickLook

/// Shows what was extracted from a document, page by page: text, notes, tables and images.
/// PDFs can switch each page between the extracted text and the rendered original page.
struct DocumentPagesView: View {
    @Bindable var document: VLDocument

    @State private var mode: Mode = .text
    @State private var quickLookURL: URL?
    @State private var enlargedImage: URL?
    @State private var showOCR = false
    @State private var showCleanUp = false
    @State private var showPrepare = false
    @State private var showRemoveEverywhere = false
    @State private var showGenerate = false
    @State private var showReader = false

    enum Mode: String, CaseIterable, Identifiable {
        case text = "Text", sentences = "Sentences", original = "Original"
        var id: Self { self }
    }

    /// PowerPoint/Word pages still to render (or failed), shown above the pages in Original.
    private var showsRenderStatus: Bool {
        document.kind != .pdf && (!document.hasOriginalPages || document.renderError != nil
                                  || PageRenderService.shared.rendering.contains(document.id))
    }

    private var sortedPages: [DocumentPage] {
        document.pages.sorted { $0.pageIndex < $1.pageIndex }
    }

    private var pageNoun: String { document.kind == .pptx ? "Slide" : "Page" }

    private var hasOCRCandidates: Bool { document.pages.contains { !$0.ocrCandidates.isEmpty } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                header
                if hasOCRCandidates && !document.pages.contains(where: { !$0.ocrResults.isEmpty }) {
                    ocrBanner
                }
                if mode == .original && showsRenderStatus {
                    RenderStatusView(document: document)
                } else if mode == .original && document.kind != .pdf && PageRenderService.isAvailable {
                    HStack {
                        Spacer()
                        Button("Render Pages Again") { PageRenderService.shared.render(document) }
                            .buttonStyle(.borderless)
                            .font(.callout)
                            .help("Make the page images again, e.g. after installing LibreOffice")
                    }
                }
                ForEach(sortedPages) { page in
                    PageCard(
                        page: page,
                        documentId: document.id,
                        title: "\(pageNoun) \(page.pageIndex + 1)",
                        mode: mode,
                        onImageTap: { enlargedImage = $0 }
                    )
                }
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.l)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        #if os(macOS)
        .background(Color.macMain)
        .environment(\.colorScheme, .dark)
        #else
        .background(Color.systemBackground)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle(document.title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 270)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showReader = true } label: {
                    Label("Listen", systemImage: "play.circle")
                }
                .help("Open the reader and listen")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showGenerate = true } label: {
                    Label("Generate Audio", systemImage: "waveform")
                }
                .help("Generate the audio with Breeze")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showPrepare = true } label: {
                    Label("Prepare", systemImage: "text.badge.checkmark")
                }
                .help("Clean up with S1-mini and split into sentences")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showRemoveEverywhere = true } label: {
                    Label("Remove from All Pages", systemImage: "text.badge.minus")
                }
                .help("Remove a piece of text (like a footer) from every page")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showCleanUp = true } label: {
                    Label("Clean Up", systemImage: "eraser")
                }
                .help("Edit or remove text before cleanup and audio")
            }
            if hasOCRCandidates {
                ToolbarItem(placement: .primaryAction) {
                    Button { showOCR = true } label: {
                        Label("Read Images", systemImage: "text.viewfinder")
                    }
                    .help("Choose which images to read with OCR")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    quickLookURL = DocumentStorage.originalURL(for: document.id, kind: document.kind)
                } label: {
                    Label("Open Original", systemImage: "doc.viewfinder")
                }
                .help("Preview the original file")
            }
        }
        .quickLookPreview($quickLookURL)
        .navigationDestination(isPresented: $showCleanUp) {
            CleanUpView(document: document)
        }
        .navigationDestination(isPresented: $showReader) {
            ReaderView(document: document)
        }
        .sheet(isPresented: $showGenerate) {
            GenerateView(document: document) {
                // Let the Generate sheet finish dismissing before presenting Prepare.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showPrepare = true }
            }
        }
        .sheet(isPresented: $showRemoveEverywhere) {
            RemoveEverywhereView(document: document)
        }
        .sheet(isPresented: $showPrepare) {
            PrepareView(document: document) { mode = .sentences }
        }
        .sheet(isPresented: $showOCR) {
            OCRSelectionView(document: document)
        }
        .sheet(item: $enlargedImage) { url in
            ImageViewer(url: url)
        }
        .onAppear {
            document.lastOpenedAt = .now
            openReaderIfRequested()
        }
        .onChange(of: AudioPlayer.shared.openReaderRequest) { openReaderIfRequested() }
        .onChange(of: document.id) { mode = .text }
        .onChange(of: mode) { _, newMode in
            if newMode == .original && PageRenderService.shared.needsRender(document) {
                PageRenderService.shared.render(document)
            }
        }
    }

    /// The mini player asked for this document's reader.
    private func openReaderIfRequested() {
        guard AudioPlayer.shared.openReaderRequest == document.id else { return }
        AudioPlayer.shared.openReaderRequest = nil
        showCleanUp = false
        showReader = true
    }

    private var header: some View {
        let pages = document.pages
        let imageCount = pages.reduce(0) { $0 + $1.imageFilePaths.count }
        let scannedCount = pages.filter(\.isLikelyScanned).count

        return HStack(spacing: DS.Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(DS.kindColor(for: document.kind).opacity(0.14))
                    .frame(width: 52, height: 52)
                Image(systemName: document.kind.sfSymbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(DS.kindColor(for: document.kind))
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(document.title)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .lineLimit(2)
                Text(summary(pages: pages.count, images: imageCount, scanned: scannedCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, DS.Space.s)
    }

    private var ocrBanner: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "text.viewfinder")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Text inside images")
                    .font(.headline)
                Text("Pick the images and scanned pages you want read aloud.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.s)
            Button("Choose") { showOCR = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(DS.Space.l)
        .cardStyle()
    }

    private func summary(pages: Int, images: Int, scanned: Int) -> String {
        var parts = [document.kind.displayName, "\(pages) \(pageNoun.lowercased())\(pages == 1 ? "" : "s")"]
        if images > 0 { parts.append("\(images) image\(images == 1 ? "" : "s")") }
        if scanned > 0 { parts.append("\(scanned) scanned") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Page card

private struct PageCard: View {
    let page: DocumentPage
    let documentId: UUID
    let title: String
    let mode: DocumentPagesView.Mode
    let onImageTap: (URL) -> Void

    @State private var isEditing = false
    /// In the Sentences view, editing works on a draft (one sentence per line) saved on Done.
    @State private var sentenceDraft = ""

    private var editsSentences: Bool { mode == .sentences }
    private var isEdited: Bool { editsSentences ? page.sentencesEdited : page.hasEdits }

    private func url(_ relative: String) -> URL {
        DocumentStorage.url(for: documentId, relativePath: relative)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            headerRow

            Group {
                if isEditing && editsSentences {
                    sentenceEditor
                } else if isEditing {
                    editContent
                } else if mode == .sentences {
                    sentencesContent
                } else if mode == .original {
                    originalContent
                } else {
                    textContent
                }
            }
            .opacity(page.isSkipped ? 0.45 : 1)
            .saturation(page.isSkipped ? 0 : 1)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .animation(.easeInOut(duration: 0.2), value: page.isSkipped)
        .animation(.easeInOut(duration: 0.2), value: isEditing)
        .onChange(of: mode) { oldMode, _ in
            // Switching views ends editing; keep what was typed in the sentence draft.
            if isEditing && oldMode == .sentences { commitSentences() }
            isEditing = false
        }
    }

    /// The rendered page(s) showing this page's content.
    @ViewBuilder
    private var originalContent: some View {
        let paths: [String] = page.document.flatMap { doc in
            doc.originalRange(for: page).map { range in range.map { doc.originalPagePaths[$0] } }
        }?.filter { !$0.isEmpty } ?? []
        if paths.isEmpty {
            Text("No rendered page yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: DS.Space.m) {
                ForEach(paths, id: \.self) { path in
                    StoredImage(url: url(path), maxPixelSize: 1600)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                        .onTapGesture { onImageTap(url(path)) }
                }
            }
        }
    }

    /// Edits the prepared (S1) sentences directly. One line = one sentence, read as one piece.
    private var sentenceEditor: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text("Sentences · one per line")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if page.sentencesEdited || sentenceDraft != page.preparedSentences.joined(separator: "\n") {
                    Button("Restore Prepared Text") {
                        sentenceDraft = page.preparedSentences.joined(separator: "\n")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            TextEditor(text: $sentenceDraft)
                .font(.body)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(DS.Space.s)
                .frame(height: sentenceEditorHeight)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
            Text("Press Return to split a sentence, or join two lines to merge them. Changes are saved when you click Editing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sentenceEditorHeight: CGFloat {
        let lines = sentenceDraft.components(separatedBy: "\n").reduce(0) { $0 + max(1, $1.count / 80 + 1) }
        return min(max(CGFloat(lines) * 22 + 16, 90), 480)
    }

    private func commitSentences() {
        page.sentences = sentenceDraft
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The prepared sentences, numbered, exactly as they'll be read.
    @ViewBuilder
    private var sentencesContent: some View {
        if page.isSkipped {
            Text("Skipped.").font(.callout).italic().foregroundStyle(.secondary)
        } else if !page.isPrepared {
            Text("Not prepared yet. Use Prepare to clean up the text and split it into sentences.")
                .font(.callout).italic().foregroundStyle(.secondary)
        } else if page.sentences.isEmpty {
            Text("Nothing to read on this page.").font(.callout).italic().foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(Array(page.sentences.enumerated()), id: \.offset) { i, sentence in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                        Text("\(i + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 22, alignment: .trailing)
                        Text(sentence)
                            .font(.body)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// Inline editors for each section, the same ones Clean Up uses.
    @ViewBuilder
    private var editContent: some View {
        if page.presentSections.isEmpty {
            Text("No text on this page to edit.")
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                ForEach(page.presentSections) { section in
                    SectionEditor(page: page, section: section, embedded: true)
                }
                if page.hasEdits {
                    Button("Restore Original Text", role: .destructive) {
                        for section in DocumentPage.Section.allCases { page.setEditedText(nil, for: section) }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: DS.Space.s) {
            Text(title).sectionHeaderStyle()
            Spacer()
            tags
                .opacity(page.isSkipped ? 0.45 : 1)
                .saturation(page.isSkipped ? 0 : 1)
            editButton
            skipButton
        }
    }

    /// Edit → Editing (text boxes open) → Edited once there are changes. Click again to edit or revert.
    private var editButton: some View {
        Button {
            if editsSentences {
                if isEditing { commitSentences() } else { sentenceDraft = page.sentences.joined(separator: "\n") }
            }
            isEditing.toggle()
        } label: {
            Text(isEditing ? "Editing" : (isEdited ? "Edited" : "Edit"))
                .font(.system(.caption, weight: .semibold))
                .frame(minWidth: 52)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isEditing || isEdited ? Color.accentColor : nil)
        .disabled(page.isSkipped || (editsSentences && !page.isPrepared))
        .help(isEditing ? "Click when you're done editing"
              : editsSentences ? "Edit the prepared sentences" : "Edit this page's extracted text")
    }

    /// Skips the whole page (it won't be read). Click again to bring it back.
    private var skipButton: some View {
        Button {
            page.isSkipped.toggle()
            if page.isSkipped {
                if isEditing && editsSentences { commitSentences() }
                isEditing = false
            }
        } label: {
            Text(page.isSkipped ? "Skipped" : "Skip")
                .font(.system(.caption, weight: .semibold))
                .frame(minWidth: 52)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(page.isSkipped ? .orange : nil)
        .help(page.isSkipped ? "This page won't be read. Click to include it again." : "Don't read this page")
    }

    @ViewBuilder
    private var tags: some View {
        HStack(spacing: DS.Space.s) {
            if page.isPrepared && !page.isSkipped && !page.sentences.isEmpty && page.audioReadyCount > 0 {
                let ready = page.audioReadyCount, total = page.sentences.count
                Tag(text: ready == total ? "Audio" : "\(ready)/\(total)", systemImage: "waveform",
                    color: ready == total ? .indigo : .gray)
            }
            if page.isPreparedStale {
                Tag(text: "Changed", systemImage: "arrow.triangle.2.circlepath", color: .orange)
            } else if page.isPrepared && !page.isSkipped {
                Tag(text: page.preparedWithS1 ? "S1" : "Ready", systemImage: "checkmark", color: .green)
            }
            if !page.cleanText(.ocr).isEmpty { Tag(text: "OCR", systemImage: "text.viewfinder", color: .green) }
            if page.isLikelyScanned { Tag(text: "Scanned", systemImage: "doc.viewfinder", color: .orange) }
            if !page.cleanText(.notes).isEmpty { Tag(text: "Notes", systemImage: "note.text", color: .purple) }
            if !page.cleanText(.tables).isEmpty { Tag(text: "Table", systemImage: "tablecells", color: .teal) }
            if page.hasImages {
                Tag(text: "\(page.imageFilePaths.count)", systemImage: "photo", color: .blue)
            }
        }
    }

    @ViewBuilder
    private var textContent: some View {
        if page.cleanText(.body).isEmpty && !page.cleanText(.ocr).isEmpty {
            EmptyView()
        } else if page.cleanText(.body).isEmpty {
            Text(page.isLikelyScanned
                 ? "No selectable text. This looks like a scanned page; its text will come from OCR."
                 : "No text on this page.")
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
        } else {
            Text(page.cleanText(.body))
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
        }

        if !page.cleanText(.ocr).isEmpty {
            LabeledBlock(label: "Text from images") {
                Text(page.cleanText(.ocr))
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
        }

        if !page.cleanText(.tables).isEmpty {
            LabeledBlock(label: "Table") { TableText(text: page.cleanText(.tables)) }
        }

        if page.hasImages {
            LabeledBlock(label: "Images") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.s) {
                        ForEach(page.imageFilePaths, id: \.self) { path in
                            StoredImage(url: url(path), maxPixelSize: 400, contentMode: .fill)
                                .frame(width: 140, height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture { onImageTap(url(path)) }
                        }
                    }
                }
            }
        }

        if !page.cleanText(.notes).isEmpty {
            LabeledBlock(label: "Speaker notes") {
                Text(page.cleanText(.notes))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Small components

private struct Tag: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(.caption2, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

private struct LabeledBlock<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(label)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(.top, DS.Space.xs)
    }
}

/// Renders tab-separated rows as a simple grid.
private struct TableText: View {
    let text: String

    var body: some View {
        let rows = text.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
        Grid(alignment: .leading, horizontalSpacing: DS.Space.l, verticalSpacing: DS.Space.s) {
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r].indices, id: \.self) { c in
                        Text(rows[r][c])
                            .font(.callout)
                            .fontWeight(r == 0 ? .semibold : .regular)
                    }
                }
                if r < rows.count - 1 { Divider() }
            }
        }
        .textSelection(.enabled)
        .padding(DS.Space.m)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
    }
}

private struct ImageViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            StoredImage(url: url, maxPixelSize: 2400)
                .padding()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 480)
        #endif
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
