import SwiftUI
import SwiftData

// MARK: - Section editor

/// Editable text box for one section of a page, with Remove All / Restore.
/// Used by Clean Up and by inline editing in the page view.
struct SectionEditor: View {
    @Bindable var page: DocumentPage
    let section: DocumentPage.Section
    /// Inside another card (page view): no card of its own.
    var embedded = false

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
        .modifier(SectionCard(embedded: embedded))
    }

    /// Rough height for the text so short sections don't get a tall empty box.
    /// Always within 90...420; longer text scrolls inside the editor.
    private var editorHeight: CGFloat {
        let text = page.cleanText(section)
        let lines = text.components(separatedBy: "\n").reduce(0) { $0 + max(1, $1.count / 80 + 1) }
        return min(max(CGFloat(lines) * 22 + 16, 90), 420)
    }
}

private struct SectionCard: ViewModifier {
    let embedded: Bool

    func body(content: Content) -> some View {
        if embedded {
            content
        } else {
            content.padding(DS.Space.l).cardStyle()
        }
    }
}
