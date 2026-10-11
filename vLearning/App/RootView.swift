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
            DocumentDetail(document: selectedDocument)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct DocumentDetail: View {
    let document: VLDocument?

    var body: some View {
        if let doc = document {
            DocumentPagesView(document: doc)
                .id(doc.id)
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
