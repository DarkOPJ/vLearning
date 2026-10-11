import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LibraryView: View {
    @Binding var selectedDocument: VLDocument?
    @Query(sort: \VLDocument.importedAt, order: .reverse) private var documents: [VLDocument]
    @Environment(\.modelContext) private var context

    @State private var showImportPicker = false
    @State private var showSettings = false
    @State private var showTasks = false
    @State private var searchText = ""
    @State private var isImporting = false
    @State private var importError: String?

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
        .overlay {
            if isImporting {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: DS.Space.m) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.accentColor)
                        Text("Importing…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(DS.Space.xxxl)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                }
            }
        }
        .alert("Import Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        #if os(macOS)
        .background(Color.macSidebar)
        .environment(\.colorScheme, .dark)
        #endif
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
        .sheet(isPresented: $showTasks) {
            BackgroundTasksView()
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
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    delete(doc)
                                }
                            }
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
        #if os(macOS)
        .scrollContentBackground(.hidden)
        .background(Color.macSidebar)
        #endif
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
        ToolbarItem(placement: .primaryAction) {
            Button { showTasks = true } label: {
                if GenerationQueue.shared.isBusy {
                    Label { Text("Background Tasks") } icon: { ProgressView().controlSize(.small) }
                } else {
                    Label("Background Tasks", systemImage: "list.bullet.rectangle")
                }
            }
            .help("Audio generation tasks")
        }
        ToolbarItem(placement: .secondaryAction) {
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    // MARK: - Actions

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard DocumentKind.from(fileExtension: url.pathExtension) != nil else {
            importError = "'\(url.pathExtension)' is not a supported format."
            return
        }

        isImporting = true
        Task {
            do {
                let doc = try await DocumentImporter.importDocument(from: url, into: context)
                selectedDocument = doc
                // PowerPoint/Word: make the "Original" page images in the background.
                if PageRenderService.shared.needsRender(doc) { PageRenderService.shared.render(doc) }
            } catch {
                importError = error.localizedDescription
            }
            isImporting = false
        }
    }

    private func deleteDocuments(at offsets: IndexSet) {
        offsets.map { filtered[$0] }.forEach(delete)
    }

    private func delete(_ doc: VLDocument) {
        if selectedDocument == doc { selectedDocument = nil }
        if AudioPlayer.shared.document?.id == doc.id { AudioPlayer.shared.close() }
        try? DocumentStorage.delete(doc.id)
        context.delete(doc)
    }
}

// MARK: - UTType extensions

extension UTType {
    static let pptx = UTType(filenameExtension: "pptx") ?? .data
    static let docx = UTType(filenameExtension: "docx") ?? .data
}
