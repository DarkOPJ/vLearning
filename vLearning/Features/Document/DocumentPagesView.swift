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

    enum Mode: String, CaseIterable, Identifiable {
        case text = "Text", original = "Original"
        var id: Self { self }
    }

    private var sortedPages: [DocumentPage] {
        document.pages.sorted { $0.pageIndex < $1.pageIndex }
    }

    private var pageNoun: String { document.kind == .pptx ? "Slide" : "Page" }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                header
                ForEach(sortedPages) { page in
                    PageCard(
                        page: page,
                        documentId: document.id,
                        title: "\(pageNoun) \(page.pageIndex + 1)",
                        showOriginal: mode == .original,
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
            if document.kind == .pdf {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
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
        .sheet(item: $enlargedImage) { url in
            ImageViewer(url: url)
        }
        .onAppear { document.lastOpenedAt = .now }
        .onChange(of: document.id) { mode = .text }
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
    let showOriginal: Bool
    let onImageTap: (URL) -> Void

    private func url(_ relative: String) -> URL {
        DocumentStorage.url(for: documentId, relativePath: relative)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            headerRow

            if showOriginal, let preview = page.previewImagePath {
                StoredImage(url: url(preview), maxPixelSize: 1600)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                    .onTapGesture { onImageTap(url(preview)) }
            } else {
                textContent
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var headerRow: some View {
        HStack(spacing: DS.Space.s) {
            Text(title).sectionHeaderStyle()
            Spacer()
            if page.isLikelyScanned { Tag(text: "Scanned", systemImage: "doc.viewfinder", color: .orange) }
            if !page.notesText.isEmpty { Tag(text: "Notes", systemImage: "note.text", color: .purple) }
            if !page.tablesText.isEmpty { Tag(text: "Table", systemImage: "tablecells", color: .teal) }
            if page.hasImages {
                Tag(text: "\(page.imageFilePaths.count)", systemImage: "photo", color: .blue)
            }
        }
    }

    @ViewBuilder
    private var textContent: some View {
        if page.extractedText.isEmpty {
            Text(page.isLikelyScanned
                 ? "No selectable text. This looks like a scanned page; its text will come from OCR."
                 : "No text on this page.")
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
        } else {
            Text(page.extractedText)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
        }

        if !page.tablesText.isEmpty {
            LabeledBlock(label: "Table") { TableText(text: page.tablesText) }
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

        if !page.notesText.isEmpty {
            LabeledBlock(label: "Speaker notes") {
                Text(page.notesText)
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
