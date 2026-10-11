import SwiftUI
import SwiftData

@main
struct vLearningApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: VLDocument.self, DocumentPage.self, GenerationJob.self)
        } catch {
            fatalError("Could not open the library: \(error)")
        }
        Notifier.shared.configure()
        GenerationQueue.shared.attach(container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1120, height: 740)
        #endif
    }
}
