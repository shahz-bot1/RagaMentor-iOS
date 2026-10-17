import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// Home screen per PLAN §10 (locked decision 10): the Now Playing card
// sits above the library; all loop management lives in the fullscreen
// view (M3/M5). Library rows: title, duration, "N loops".

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var controller: PlaybackController
    @Query(sort: \Song.dateAdded, order: .reverse) private var songs: [Song]
    @State private var showImporter = false

    var body: some View {
        List {
            if let song = controller.currentSong {
                Section {
                    NowPlayingCard(song: song)
                }
            }
            Section {
                if songs.isEmpty {
                    ContentUnavailableView {
                        Label("No songs yet", systemImage: "music.note.list")
                    } description: {
                        Text("Import an audio file to start practising. Re-importing the same file reopens the existing song, loops intact.")
                    }
                } else {
                    ForEach(songs) { song in
                        Button {
                            controller.open(song)
                        } label: {
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
        .onAppear { controller.modelContext = modelContext }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showImporter = true
                } label: {
                    Label("Import", systemImage: "plus")
                }
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, let last = controller.importFiles(urls, context: modelContext) {
                controller.open(last)
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

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct NowPlayingCard: View {
    @EnvironmentObject private var controller: PlaybackController
    let song: Song

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(LibraryView.formatDuration(controller.position)) / \(LibraryView.formatDuration(song.duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    controller.closeSong()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Slider(value: Binding(
                get: { controller.position },
                set: { controller.seek(to: $0) }
            ), in: 0...max(song.duration, 0.01))
            .disabled(song.duration <= 0)

            HStack(spacing: 20) {
                Button { controller.skip(by: -10) } label: {
                    Image(systemName: "gobackward.10")
                }
                Button {
                    controller.togglePlay()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                Button { controller.skip(by: 10) } label: {
                    Image(systemName: "goforward.10")
                }
            }
            .frame(maxWidth: .infinity)

            Picker("Speed", selection: $controller.speed) {
                ForEach(PlaybackController.speedPresets, id: \.self) { preset in
                    Text("\(preset, specifier: "%g")x").tag(preset)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                Button {
                    controller.setA()
                } label: {
                    Text(controller.pendingA == nil ? "Set A" : "A \(short(controller.pendingA!))")
                }
                .buttonStyle(.bordered)
                Button {
                    controller.setB()
                } label: {
                    Text(controller.pendingB == nil ? "Set B" : "B \(short(controller.pendingB!))")
                }
                .buttonStyle(.bordered)
                if controller.pendingA != nil || controller.pendingB != nil {
                    Button("Clear") { controller.clearPendingMarks() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button {
                    controller.toggleLoopOn()
                } label: {
                    Label("Loop", systemImage: "repeat")
                }
                .buttonStyle(.bordered)
                .tint(controller.loopOn ? .accentColor : .gray)
                .disabled(controller.selectedLoop == nil)
            }
            .font(.subheadline)

            NavigationLink {
                LoopsView(song: song)
            } label: {
                HStack {
                    Text("Loops")
                    Spacer()
                    Text("\(song.loops.count)")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func short(_ t: Double) -> String { LibraryView.formatDuration(t) }
}
