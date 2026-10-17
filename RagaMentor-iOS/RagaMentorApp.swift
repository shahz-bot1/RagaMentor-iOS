import SwiftUI
import SwiftData

@main
struct RagaMentorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Song.self, LoopRegion.self, LoopGroup.self])
    }
}
