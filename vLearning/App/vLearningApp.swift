import SwiftUI
import SwiftData

@main
struct vLearningApp: App {
    private let container: ModelContainer
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            container = try ModelContainer(for: VLDocument.self, DocumentPage.self, GenerationJob.self)
        } catch {
            fatalError("Could not open the library: \(error)")
        }
        Notifier.shared.configure()
        GenerationQueue.shared.attach(container.mainContext)
        SyncStore.attach(container.mainContext)
        #if os(macOS)
        SyncServer.shared.startIfEnabled()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                #if os(iOS)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active:     SyncClient.shared.activate()
                    case .background: SyncClient.shared.deactivate()
                    default:          break
                    }
                }
                #endif
        }
        .modelContainer(container)
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1120, height: 740)
        #endif
    }
}
