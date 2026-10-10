import SwiftUI
import SwiftData

@main
struct vLearningApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [VLDocument.self, DocumentPage.self, GenerationJob.self])
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1120, height: 740)
        #endif
    }
}
