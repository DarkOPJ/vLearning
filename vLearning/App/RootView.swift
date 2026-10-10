import SwiftUI
import SwiftData

struct RootView: View {
    @State private var selectedDocument: VLDocument?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibraryView(selectedDocument: $selectedDocument)
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
                #endif
        } detail: {
            DocumentDetailPlaceholder(document: selectedDocument)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// Placeholder until the reader is built in step 8
private struct DocumentDetailPlaceholder: View {
    let document: VLDocument?

    var body: some View {
        if let doc = document {
            VStack(spacing: DS.Space.m) {
                Image(systemName: doc.kind.sfSymbol)
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Color.accentColor)
                Text(doc.title)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                Text("Reader coming in step 8")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(macOS)
            .background(Color.macMain)
            .environment(\.colorScheme, .dark)
            #else
            .background(Color.systemBackground)
            #endif
        } else {
            ContentUnavailableView(
                "No Document Selected",
                systemImage: "book.closed",
                description: Text("Pick a document from the library to get started.")
            )
            #if os(macOS)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.macMain)
            .environment(\.colorScheme, .dark)
            #endif
        }
    }
}
