import SwiftUI
import SwiftData

/// Paste a piece of text (a footer, watermark, repeated heading) and remove it from every page.
/// Removals are stored as Clean Up edits, so each page can still be restored; Undo reverts the batch.
struct RemoveEverywhereView: View {
    @Bindable var document: VLDocument
    @Environment(\.dismiss) private var dismiss

    @State private var rule = TextRemovalRule(text: "")
    /// Edits as they were before the last removal, for Undo.
    @State private var undoSnapshot: [(page: DocumentPage, section: DocumentPage.Section, edit: String?)]?
    @State private var lastResult: String?

    private var pages: [DocumentPage] { document.pages.sorted { $0.pageIndex < $1.pageIndex } }
    private var pageNoun: String { document.kind == .pptx ? "Slide" : "Page" }

    private struct Hit: Identifiable {
        let page: DocumentPage
        let count: Int
        let context: (before: String, match: String, after: String)?
        var id: PersistentIdentifier { page.id }
    }

    private var hits: [Hit] {
        guard !rule.isEmpty, let regex = rule.regex() else { return [] }
        return pages.compactMap { page in
            var count = 0
            var context: (String, String, String)?
            for section in DocumentPage.Section.allCases {
                let text = page.cleanText(section)
                count += TextRemover.count(in: text, regex: regex)
                if context == nil { context = TextRemover.firstMatchContext(in: text, regex: regex) }
            }
            return count > 0 ? Hit(page: page, count: count, context: context) : nil
        }
    }

    var body: some View {
        let hits = hits
        let total = hits.reduce(0) { $0 + $1.count }

        VStack(spacing: 0) {
            Text("Remove from All Pages")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.m)
                .background(.bar)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    input
                    options
                    if let lastResult { resultBanner(lastResult) }
                    preview(hits: hits, total: total)
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack(spacing: DS.Space.m) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(total == 0 ? "Remove" : "Remove \(total) from \(hits.count) \(pageNoun.lowercased())\(hits.count == 1 ? "" : "s")",
                       role: .destructive) {
                    apply()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(total == 0)
            }
            .controlSize(.large)
            .padding(DS.Space.l)
            .background(.bar)
        }
        #if os(macOS)
        .frame(width: 620, height: 600)
        #endif
    }

    // MARK: - Sections

    private var input: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Text to remove")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Paste text that appears on many pages, e.g. a footer", text: $rule.text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(DS.Space.m)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                .onChange(of: rule) { lastResult = nil }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Toggle("Ignore capitalization", isOn: $rule.ignoreCase)
            Toggle("Any number (\"Page 3 of 20\" also matches \"Page 4 of 20\")", isOn: $rule.anyNumber)
            Toggle("Remove the whole line it's on", isOn: $rule.wholeLine)
        }
        #if os(macOS)
        .toggleStyle(.checkbox)
        #endif
        .font(.callout)
    }

    private func resultBanner(_ text: String) -> some View {
        HStack(spacing: DS.Space.m) {
            Label(text, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Spacer()
            if undoSnapshot != nil {
                Button("Undo", action: undo)
                    .buttonStyle(.bordered)
            }
        }
        .font(.callout)
        .padding(DS.Space.m)
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
    }

    @ViewBuilder
    private func preview(hits: [Hit], total: Int) -> some View {
        if rule.isEmpty {
            Text("Tip: select the text on a page, copy it, and paste it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if hits.isEmpty {
            Text(lastResult == nil ? "Not found on any \(pageNoun.lowercased())." : "Nothing left to remove.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Found \(total) time\(total == 1 ? "" : "s") on \(hits.count) \(pageNoun.lowercased())\(hits.count == 1 ? "" : "s")")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(hits) { hit in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                        Text("\(pageNoun) \(hit.page.pageIndex + 1)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .frame(width: 64, alignment: .leading)
                        if let c = hit.context {
                            (Text(c.before).foregroundStyle(.secondary)
                             + Text(c.match).foregroundStyle(.red).strikethrough()
                             + Text(c.after).foregroundStyle(.secondary))
                                .font(.callout)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if hit.count > 1 {
                            Text("×\(hit.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Actions

    private func apply() {
        guard let regex = rule.regex() else { return }
        var snapshot: [(DocumentPage, DocumentPage.Section, String?)] = []
        var removed = 0
        var touchedPages = 0

        for page in pages {
            var touched = false
            for section in DocumentPage.Section.allCases {
                let text = page.cleanText(section)
                let n = TextRemover.count(in: text, regex: regex)
                guard n > 0 else { continue }
                snapshot.append((page, section, page.editedText(section)))
                page.setEditedText(TextRemover.remove(from: text, regex: regex), for: section)
                removed += n
                touched = true
            }
            if touched { touchedPages += 1 }
        }

        undoSnapshot = snapshot
        lastResult = "Removed \(removed) from \(touchedPages) \(pageNoun.lowercased())\(touchedPages == 1 ? "" : "s")."
    }

    private func undo() {
        for item in undoSnapshot ?? [] {
            item.page.setEditedText(item.edit, for: item.section)
        }
        undoSnapshot = nil
        lastResult = nil
    }
}
