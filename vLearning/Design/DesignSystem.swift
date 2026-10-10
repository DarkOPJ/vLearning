import SwiftUI

enum DS {

    // MARK: - Spacing (8pt grid)

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
        static let huge: CGFloat = 48
    }

    // MARK: - Corner radius

    enum Radius {
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let full: CGFloat = 999
    }

    // MARK: - Document kind

    static func kindColor(for kind: DocumentKind) -> Color {
        switch kind {
        case .pdf:  Color(red: 0.91, green: 0.22, blue: 0.20)  // warm red
        case .pptx: Color(red: 0.93, green: 0.50, blue: 0.15)  // orange
        case .docx: Color(red: 0.22, green: 0.51, blue: 0.95)  // blue
        }
    }
}

// MARK: - Cross-platform Color helpers

extension Color {
    static var vlCard: Color { Color("CardBackground") }

    static var systemBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var secondarySystemBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    // macOS-specific chrome colors (fixed dark, independent of system appearance)
    #if os(macOS)
    static let macSidebar  = Color(red: 0.13, green: 0.13, blue: 0.145)  // dark
    static let macMain     = Color(red: 0.075, green: 0.075, blue: 0.082) // very dark graphite
    static let macCard     = Color(red: 0.20, green: 0.20, blue: 0.22)    // elevated surface on dark bg
    #endif
}

// MARK: - View modifiers

extension View {
    func cardStyle() -> some View {
        #if os(macOS)
        self
            .background(Color.macCard)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        #else
        self
            .background(Color.vlCard)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        #endif
    }

    func sectionHeaderStyle() -> some View {
        self
            .font(.system(.footnote, design: .default, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }
}
