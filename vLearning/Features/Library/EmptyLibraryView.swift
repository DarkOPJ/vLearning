import SwiftUI

struct EmptyLibraryView: View {
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: DS.Space.xxl) {
            Spacer()

            VStack(spacing: DS.Space.xl) {
                iconStack

                VStack(spacing: DS.Space.s) {
                    Text("No Documents Yet")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("Import a PDF, PowerPoint or Word file\nand vLearning will read it aloud.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }

                importButton
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.Space.xxxl)
    }

    // MARK: - Subviews

    private var iconStack: some View {
        ZStack {
            ForEach(Array(DocumentKind.allCases.enumerated()), id: \.offset) { idx, kind in
                let offsets: [(CGFloat, CGFloat, Double)] = [
                    (-28, -8, -12),
                    (28, -8, 12),
                    (0, 4, 0),
                ]
                let (dx, dy, angle) = offsets[idx]
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(DS.kindColor(for: kind).opacity(0.12))
                    .frame(width: 64, height: 80)
                    .overlay {
                        Image(systemName: kind.sfSymbol)
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(DS.kindColor(for: kind))
                    }
                    .rotationEffect(.degrees(angle))
                    .offset(x: dx, y: dy)
            }
        }
        .frame(height: 120)
    }

    private var importButton: some View {
        Button(action: onImport) {
            Label("Import a Document", systemImage: "arrow.down.doc")
                .font(.system(.body, design: .default, weight: .semibold))
                .padding(.horizontal, DS.Space.xxl)
                .padding(.vertical, DS.Space.m)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .cursor(.pointingHand)
        #endif
    }
}

// macOS cursor modifier (no-op on iOS)
#if os(macOS)
private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
#endif

#Preview {
    EmptyLibraryView(onImport: {})
        .frame(width: 360, height: 500)
}
