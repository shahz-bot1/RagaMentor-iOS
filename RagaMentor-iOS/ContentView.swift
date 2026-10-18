import SwiftUI
import SwiftData
import LoopLab
import AudioKit
import PersistenceKit
import Composer
import RagaBrowser
import Varisai
import Tala

struct ContentView: View {
    @StateObject private var controller: PlaybackController
    /// The app's ONE tone engine and ONE sequence player (P-E):
    /// built here in the shell; every studio's adapter wraps
    /// this player and nothing else constructs an engine.
    @StateObject private var sequencePlayer: SequencePlayer

    init() {
        let tone = HarmoniumToneEngine()
        let player = SequencePlayer(tone: tone)
        _sequencePlayer = StateObject(wrappedValue: player)
        _controller = StateObject(wrappedValue:
            PlaybackController(sequencePlayer: player))
    }
    /// Cross-studio audio focus (P6): one registry shared with
    /// every studio through the environment.
    @StateObject private var audioFocus = StudioAudioFocus()
    @Environment(\.scenePhase) private var scenePhase
    /// The shared theme setting (PARITY-PLAN §10): one in-app
    /// setting for all studios, default dark like the web.
    @AppStorage("ragamentor-theme") private var theme = "dark"
    /// Compose Studio storage (P2).
    private let compositionStore = UserDefaultsCompositionStore()

    var body: some View {
        TabView {
            // LibraryView owns its path-driven stack (song detail
            // is pushed from the list).
            LibraryView()
                .tabItem { Label("LoopLab", systemImage: "waveform") }

            NavigationStack {
                CompositionListView(
                    store: compositionStore,
                    library: controller.ragaLibrary,
                    player: controller.phraseAdapter,
                    onPlayStart: { controller.pause() })
            }
            .tabItem { Label("Compose", systemImage: "square.and.pencil") }

            RagaBrowserView(library: controller.ragaLibrary,
                            sequencePlayer: sequencePlayer)
                .tabItem { Label("Ragas", systemImage: "music.note.house") }

            VarisaiView(onPlayStart: {
                controller.pause()
                controller.phraseAdapter.stop()
            }, sequencePlayer: sequencePlayer)
            .tabItem { Label("Varisai", systemImage: "music.note.list") }

            TalaStudioView(onPlayStart: {
                controller.pause()
                controller.phraseAdapter.stop()
            })
            .tabItem { Label("Tala", systemImage: "metronome") }
        }
        .preferredColorScheme(theme == "light" ? .light : .dark)
        .environmentObject(controller)
        .environmentObject(audioFocus)
        .onAppear {
            // Song and section-phrase playback stop every other
            // studio (P6 focus).
            controller.onSongStart = { audioFocus.stopAll() }
            controller.onPhraseStart = { audioFocus.stopAll() }
        }
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
