import SwiftUI

struct DocumentCard: View {
    let document: VLDocument

    var body: some View {
        HStack(spacing: DS.Space.m) {
            kindIcon
            info
            Spacer(minLength: DS.Space.s)
            trailing
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .cardStyle()
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
    }

    // MARK: - Subviews

    private var kindIcon: some View {
        let color = DS.kindColor(for: document.kind)
        return ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .fill(color.opacity(0.12))
                .frame(width: 46, height: 46)
            Image(systemName: document.kind.sfSymbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(color)
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(document.title)
                .font(.system(.headline, design: .default, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            HStack(spacing: DS.Space.xs) {
                Text(document.kind.displayName)
                    .foregroundStyle(DS.kindColor(for: document.kind))
                    .fontWeight(.medium)
                dot
                pageCount
                if let opened = document.lastOpenedAt {
                    dot
                    Text(opened, style: .relative)
                        .foregroundStyle(.tertiary)
                } else {
                    dot
                    Text(document.importedAt, style: .date)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(.caption, design: .default))
            .foregroundStyle(.secondary)
        }
    }

    private var trailing: some View {
        VStack(alignment: .trailing, spacing: DS.Space.s) {
            StatusBadge(status: document.generationStatus)

            if document.generationStatus == .generating && document.totalPages > 0 {
                ProgressView(value: document.progressFraction)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                    .frame(width: 60)
            }
        }
    }

    private var dot: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    private var pageCount: some View {
        let n = document.totalPages
        return Text(n == 0 ? "—" : "\(n) \(n == 1 ? "page" : "pages")")
    }
}

// MARK: - Preview

#Preview {
    let docs: [VLDocument] = [
        { let d = VLDocument(title: "Introduction to Cellular Biology", kind: .pdf, totalPages: 42); d.generationStatus = .complete; return d }(),
        { let d = VLDocument(title: "Q3 Strategy Deck", kind: .pptx, totalPages: 18); d.generationStatus = .generating; d.generationProgress = 9; return d }(),
        { let d = VLDocument(title: "Research Proposal Draft", kind: .docx, totalPages: 7); d.generationStatus = .notStarted; return d }(),
        { let d = VLDocument(title: "Annual Report 2024", kind: .pdf, totalPages: 124); d.generationStatus = .queued; return d }(),
    ]

    VStack(spacing: DS.Space.s) {
        ForEach(docs) { DocumentCard(document: $0) }
    }
    .padding()
    .background(Color.systemBackground)
}
