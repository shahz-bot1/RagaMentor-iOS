import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PersistenceKit
import SwaraEditor
import RagaBrowser
import DesignSystem

// The song library: rows PUSH a SongDetailView onto the stack
// (waveform, transport, Loops/A–B/More) instead of expanding a
// player card inline. Library rows: title, duration, "N loops".

public struct LibraryView: View {
    public init() {}
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var controller: PlaybackController
    @Query(sort: \Song.dateAdded, order: .reverse) private var songs: [Song]
    @State private var showImporter = false
    @State private var showSettings = false
    /// The navigation path: songs only. The swara editor is NOT
    /// a stack value — it is presented as a full-screen cover
    /// from here (v1.5.7, both studios, for consistency). Three
    /// stack-based designs failed on device in LoopLab: a [Song]
    /// path could not hold the session value; an item binding
    /// beside the path popped the song along with the editor;
    /// and a plain path value still landed on this list on
    /// close, while the same editor closes correctly in Compose
    /// — whose parent is its root, so a collapse to root is
    /// invisible there. A cover removes the stack from the
    /// equation: the pushed song stays underneath, untouched,
    /// and dismissal returns to it by construction.
    @State private var path = NavigationPath()
    /// The editor presentation (cover), forwarded up from the
    /// detail via onEditSwaras: SongDetailView → LoopsView's
    /// Edit/Add actions build the session, the library presents
    /// it. The session's model is built once, in the tap action.
    @State private var editorSession: LoopsView.EditorSession?

    public var body: some View {
        NavigationStack(path: $path) {
        List {
            Section {
                if songs.isEmpty {
                    ContentUnavailableView {
                        Label("No songs yet", systemImage: "music.note.list")
                    } description: {
                        Text("Import an audio file to start practising. Re-importing the same file reopens the existing song, loops intact.")
                    }
                } else {
                    ForEach(songs) { song in
                        NavigationLink(value: song) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text("\(Self.formatDuration(song.duration)) · \(song.loops.count) loop\(song.loops.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if controller.currentSong?.id == song.id {
                                    Image(systemName: controller.isPlaying ? "speaker.wave.2.fill" : "pause.circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            controller.deleteSong(songs[index], context: modelContext)
                        }
                    }
                }
            }
        }
        .navigationTitle("LoopLab Studio")
        .navigationDestination(for: Song.self) { song in
            SongDetailView(song: song, onEditSwaras: { editorSession = $0 })
                .onAppear {
                    // Open the pushed song (a no-op when it is the
                    // one already loaded, so popping back and forth
                    // never restarts playback).
                    if controller.currentSong?.id != song.id {
                        controller.open(song)
                    }
                }
        }
        .fullScreenCover(item: $editorSession) { session in
            SwaraEditorView(
                model: session.model,
                title: session.loop.name,
                browseSheet: { model, dismiss in
                    AnyView(RagaBrowserView(
                        library: model.library, mode: .pick,
                        sequencePlayer: model.player.player,
                        onPick: { raga in
                            model.applyBrowsedRaga(raga)
                            dismiss()
                        },
                        onCancel: dismiss))
                },
                onClose: { editorSession = nil },
                onCancel: { editorSession = nil })
        }
        .studioList()
        .onAppear { controller.modelContext = modelContext }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showImporter = true
                } label: {
                    Label("Import", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, let last = controller.importFiles(urls, context: modelContext) {
                controller.open(last)
                path.append(last)
            }
        }
        .alert("Import", isPresented: Binding(
            get: { controller.importError != nil },
            set: { if !$0 { controller.importError = nil } }
        )) {
            Button("OK", role: .cancel) { controller.importError = nil }
        } message: {
            Text(controller.importError ?? "")
        }
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
