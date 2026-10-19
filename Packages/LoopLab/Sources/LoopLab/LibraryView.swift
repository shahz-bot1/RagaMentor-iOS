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
    /// The navigation path. It must be a type-erased
    /// NavigationPath, NOT [Song]: the stack holds two value
    /// types — Song (the detail) and EditorSession (the swara
    /// editor). A homogeneous [Song] path cannot accept the
    /// session value, so the editor push had nowhere to go and
    /// the stack fell back to this list — the real cause of the
    /// Edit navigation bug (v1.5.5; root registration in v1.5.0
    /// was necessary but not sufficient). Compose never hit it:
    /// its stack carries no typed path at all.
    @State private var path = NavigationPath()
    /// The swara editor presentation, owned HERE at the stack
    /// root: a navigation destination registered inside the
    /// pushed song detail did not push reliably — tapping Edit
    /// collapsed the stack back to this list (his bug report;
    /// v1.4.7's hoist to the detail page was not enough). The
    /// detail forwards the built session up via onEditSwaras.
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
        .navigationTitle("RagaMentor")
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
        .navigationDestination(item: $editorSession) { session in
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
                onClose: { editorSession = nil })
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
