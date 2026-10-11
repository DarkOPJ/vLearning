import SwiftUI

/// Asks before deleting a document's generated audio. Everything else about the document stays.
private struct DeleteAudioConfirmation: ViewModifier {
    @Binding var document: VLDocument?
    @State private var blocked = false

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Delete the audio for “\(document?.title ?? "")”?",
                isPresented: Binding(get: { document != nil }, set: { if !$0 { document = nil } }),
                titleVisibility: .visible,
                presenting: document
            ) { doc in
                Button("Delete Audio", role: .destructive) {
                    blocked = !GenerationQueue.shared.deleteAudio(for: doc)
                }
                Button("Cancel", role: .cancel) {}
            } message: { doc in
                let size = ByteCountFormatter.string(fromByteCount: DocumentStorage.audioSize(for: doc), countStyle: .file)
                Text("Frees \(size). The text, edits, image text, sentences and reading position are kept, so you can generate the audio again later.")
            }
            .alert("Audio is being generated", isPresented: $blocked) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Stop this document's task in Background Tasks first, then delete its audio.")
            }
    }
}

extension View {
    /// Presents the delete-audio confirmation while `document` is set.
    func deleteAudioConfirmation(for document: Binding<VLDocument?>) -> some View {
        modifier(DeleteAudioConfirmation(document: document))
    }
}

extension VLDocument {
    /// Has any generated audio that could be deleted.
    var hasGeneratedAudio: Bool { pages.contains { !$0.sentenceAudio.isEmpty || $0.audioFilePath != nil } }
}
