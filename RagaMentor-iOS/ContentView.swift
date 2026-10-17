import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var controller = PlaybackController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            LibraryView()
        }
        .environmentObject(controller)
        .onChange(of: scenePhase) {
            // Persist the resume point when leaving the foreground
            // (PLAN §11 state restore).
            if scenePhase == .background || scenePhase == .inactive {
                controller.savePosition()
            }
        }
        .alert("Playback", isPresented: Binding(
            get: { controller.playbackError != nil },
            set: { if !$0 { controller.playbackError = nil } }
        )) {
            Button("OK", role: .cancel) { controller.playbackError = nil }
        } message: {
            Text(controller.playbackError ?? "")
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Song.self, LoopRegion.self, LoopGroup.self], inMemory: true)
}
