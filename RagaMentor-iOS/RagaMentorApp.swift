import SwiftUI
import SwiftData
import PersistenceKit
import DesignSystem

// AppShell (PARITY-PLAN §3.1): owns the store, applies the design
// tokens, and hosts the features. Feature code lives in packages.
@main
struct RagaMentorApp: App {
    /// The one song store for the app (SwiftData, on-device).
    private let store = try! SwiftDataSongStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(DesignTokens.accent)
        }
        .modelContainer(store.container)
    }
}
