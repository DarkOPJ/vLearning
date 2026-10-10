import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LibraryView: View {
    @Binding var selectedDocument: VLDocument?
    @Query(sort: \VLDocument.importedAt, order: .reverse) private var documents: [VLDocument]
    @Environment(\.modelContext) private var context

    @State private var showImportPicker = false
    @State private var showSettings = false
    @State private var searchText = ""

    private var filtered: [VLDocument] {
        guard !searchText.isEmpty else { return documents }
        return documents.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            if documents.isEmpty {
                EmptyLibraryView { showImportPicker = true }
            } else {
                libraryList
            }
        }
        .navigationTitle("Library")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .searchable(text: $searchText, prompt: "Search documents")
        .toolbar { toolbarContent }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.pdf, .pptx, .docx],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    // MARK: - Subviews

    private var libraryList: some View {
        List(selection: $selectedDocument) {
            if !filtered.isEmpty {
                Section {
                    ForEach(filtered) { doc in
                        DocumentCard(document: doc)
                            .tag(doc)
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .onDelete(perform: deleteDocuments)
                }
            } else {
                ContentUnavailableView.search(text: searchText)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: filtered.count)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { showImportPicker = true } label: {
                Label("Import", systemImage: "plus")
                    .fontWeight(.semibold)
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    // MARK: - Actions

    private func handleImport(_ result: Result<[URL], Error>) {
        // Full implementation in step 3 — stub accepted here so the file picker wires up
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard let kind = DocumentKind.from(fileExtension: url.pathExtension) else { return }

        let stub = VLDocument(
            title: url.deletingPathExtension().lastPathComponent,
            kind: kind,
            totalPages: 0
        )
        context.insert(stub)
        selectedDocument = stub
    }

    private func deleteDocuments(at offsets: IndexSet) {
        for i in offsets {
            context.delete(filtered[i])
        }
    }
}

// MARK: - UTType extensions

extension UTType {
    static let pptx = UTType(filenameExtension: "pptx") ?? .data
    static let docx = UTType(filenameExtension: "docx") ?? .data
}
