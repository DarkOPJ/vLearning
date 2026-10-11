import SwiftUI
import SwiftData
import QuickLook

/// Page-by-page editing before S1-mini: remove anything you don't want read.
/// Edits are stored separately from the extracted text, so each section can be restored.
struct CleanUpView: View {
    @Bindable var document: VLDocument

    @State private var index = 0
    @State private var showOriginal = false
    @State private var quickLookURL: URL?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var pages: [DocumentPage] { document.pages.sorted { $0.pageIndex < $1.pageIndex } }
    private var pageNoun: String { document.kind == .pptx ? "Slide" : "Page" }

    /// Side by side on the Mac and on wide iPad windows; on iPhone the original replaces the text.
    private var sideBySide: Bool {
        #if os(iOS)
        sizeClass == .regular
        #else
        true
        #endif
    }

    var body: some View {
        let pages = pages
        VStack(spacing: 0) {
            if pages.isEmpty {
                ContentUnavailableView("No Pages", systemImage: "doc", description: Text("Nothing to clean up."))
            } else {
                let page = pages[min(index, pages.count - 1)]
                content(for: page)
                    .id(page.id)
                Divider()
                pager(count: pages.count)
            }
        }
        #if os(macOS)
        .background(Color.macMain)
        .environment(\.colorScheme, .dark)
        #else
        .background(Color.systemBackground)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("Clean Up")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if document.kind == .pdf {
                        withAnimation(.easeInOut(duration: 0.2)) { showOriginal.toggle() }
                    } else {
                        quickLookURL = DocumentStorage.originalURL(for: document.id, kind: document.kind)
                    }
                } label: {
                    Label(showOriginal ? "Hide Original" : "Show Original", systemImage: "doc.viewfinder")
                }
                .help(document.kind == .pdf ? "Show the original page next to the text" : "Preview the original file")
            }
        }
        .quickLookPreview($quickLookURL)
    }

    // MARK: - Page content

    @ViewBuilder
    private func content(for page: DocumentPage) -> some View {
        let original = showOriginal ? page.previewImagePath : nil
        if let original, sideBySide {
            HStack(spacing: 0) {
                ScrollView { originalImage(original) .padding(DS.Space.l) }
                    .frame(maxWidth: .infinity)
                Divider()
                editor(for: page)
                    .frame(maxWidth: .infinity)
            }
        } else if let original {
            ScrollView { originalImage(original).padding(DS.Space.l) }
        } else {
            editor(for: page)
        }
    }

    private func originalImage(_ path: String) -> some View {
        StoredImage(url: DocumentStorage.url(for: document.id, relativePath: path), maxPixelSize: 1800)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
    }

    private func editor(for page: DocumentPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                pageHeader(page)

                if page.isSkipped {
                    Label("This \(pageNoun.lowercased()) won't be read.", systemImage: "speaker.slash")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.l)
                        .cardStyle()
                } else if page.presentSections.isEmpty {
                    Text(page.isLikelyScanned
                         ? "No text yet. This looks like a scanned page; choose it in Read Images to get its text."
                         : "No text on this \(pageNoun.lowercased()).")
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(page.presentSections) { section in
                        SectionEditor(page: page, section: section)
                    }
                }
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private func pageHeader(_ page: DocumentPage) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.m) {
                Text("\(pageNoun) \(page.pageIndex + 1)")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                Spacer()
                if page.hasEdits {
                    Button("Restore Original") {
                        withAnimation {
                            for section in DocumentPage.Section.allCases { page.setEditedText(nil, for: section) }
                        }
                    }
                    .buttonStyle(.borderless)
                }
                Toggle("Read", isOn: Binding(
                    get: { !page.isSkipped },
                    set: { newValue in withAnimation { page.isSkipped = !newValue } }
                ))
                .toggleStyle(.switch)
                .fixedSize()
                .help("Turn off to skip this \(pageNoun.lowercased()) entirely")
            }
            Text("Remove anything you don't want read aloud. Only what's left goes on to cleanup and audio.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Pager

    private func pager(count: Int) -> some View {
        HStack(spacing: DS.Space.m) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { index = max(index - 1, 0) }
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(index == 0)
            .keyboardShortcut(.leftArrow, modifiers: .command)

            Spacer()

            Menu {
                ForEach(pages.indices, id: \.self) { i in
                    Button(label(for: pages[i], at: i)) { index = i }
                }
            } label: {
                Text("\(pageNoun) \(index + 1) of \(count)")
                    .font(.callout.monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { index = min(index + 1, count - 1) }
            } label: {
                HStack(spacing: DS.Space.xs) {
                    Text("Next")
                    Image(systemName: "chevron.right")
                }
            }
            .disabled(index >= count - 1)
            .keyboardShortcut(.rightArrow, modifiers: .command)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .background(.bar)
    }

    private func label(for page: DocumentPage, at i: Int) -> String {
        var text = "\(pageNoun) \(i + 1)"
        if page.isSkipped { text += " — skipped" } else if page.hasEdits { text += " — edited" }
        return text
    }
}

// MARK: - Section editor

private struct SectionEditor: View {
    @Bindable var page: DocumentPage
    let section: DocumentPage.Section

    private var text: Binding<String> {
        Binding(get: { page.cleanText(section) },
                set: { page.setEditedText($0, for: section) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text(section.title)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                if page.isEdited(section) {
                    Text("Edited")
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                Spacer()
                if page.isEdited(section) {
                    Button("Restore") { page.setEditedText(nil, for: section) }
                }
                Button("Remove All", role: .destructive) { page.setEditedText("", for: section) }
                    .disabled(page.cleanText(section).isEmpty)
            }
            .buttonStyle(.borderless)
            .font(.caption)

            TextEditor(text: text)
                .font(section == .tables ? .system(.body, design: .monospaced) : .body)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(DS.Space.s)
                .frame(height: editorHeight)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
        }
        .padding(DS.Space.l)
        .cardStyle()
    }

    /// Rough height for the text so short sections don't get a tall empty box.
    /// Always within 90...420; longer text scrolls inside the editor.
    private var editorHeight: CGFloat {
        let text = page.cleanText(section)
        let lines = text.components(separatedBy: "\n").reduce(0) { $0 + max(1, $1.count / 80 + 1) }
        return min(max(CGFloat(lines) * 22 + 16, 90), 420)
    }
}
