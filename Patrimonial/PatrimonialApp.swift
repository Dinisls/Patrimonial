import SwiftUI
import SwiftData

@main
struct PatrimonialApp: App {
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try PersistenceController.makeContainer()
        } catch {
            fatalError("Failed to initialize SwiftData: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            PBRootView()
        }
        .modelContainer(modelContainer)
    }
}
