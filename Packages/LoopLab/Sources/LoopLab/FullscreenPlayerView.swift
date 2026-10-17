import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import RagaCore
import PersistenceKit
import DesignSystem

// Fullscreen player (PLAN §10): waveform on top, a tabbed panel
// (Loops / A–B / More), and a persistent mini-transport. The waveform
// auto-follows the playhead while playing; a tap is a hard seek that
// overrides an active loop (PLAN §9).

struct FullscreenPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var controller: PlaybackController
    let song: Song

    @State private var peaks: [Float] = []
    @State private var window = WaveformWindow(duration: 1)
    @State private var follow = true
    @State private var tab: Tab = .loops

    enum Tab: String, CaseIterable { case loops = "Loops", ab = "A–B", more = "More" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                WaveformView(peaks: peaks,
                             duration: song.duration,
                             position: controller.position,
                             loopStart: controller.selectedLoop?.start,
                             loopEnd: controller.selectedLoop?.end,
                             window: $window,
                             zoomPanEnabled: true,
                             onSeek: hardSeek)
                    .frame(height: 150)
                    .padding(.horizontal)

                HStack {
                    Text("\(LibraryView.formatDuration(window.start)) – \(LibraryView.formatDuration(window.end)) of \(LibraryView.formatDuration(song.duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        follow.toggle()
                    } label: {
                        Label("Follow", systemImage: follow ? "location.fill" : "location")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(follow ? .accentColor : .gray)
                    Button("Reset zoom") { window = WaveformWindow(duration: song.duration) }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                StudioSegmented(
                    items: Tab.allCases.map { ($0, $0.rawValue) },
                    selection: $tab)
                .padding(.horizontal)

                Group {
                    switch tab {
                    case .loops:
                        LoopsView(song: song)
                    case .ab:
                        ABTabView(song: song)
                    case .more:
                        MoreTabView(song: song)
                    }
                }
                .frame(maxHeight: .infinity)

                Divider()
                miniTransport
            }
            .background(Studio.bg.ignoresSafeArea())
            .navigationTitle(song.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: song.id) {
                window = WaveformWindow(duration: song.duration)
                peaks = await SongPeaks.peaks(for: song)
            }
            .onChange(of: controller.position) {
                if follow && controller.isPlaying {
                    window = window.following(controller.position)
                }
            }
        }
    }

    private var miniTransport: some View {
        VStack(spacing: 8) {
            HStack(spacing: 22) {
                Spacer()
                StudioRoundButton(systemImage: "gobackward.10", diameter: 38, filled: false) {
                    controller.skip(by: -10)
                }
                StudioRoundButton(systemImage: controller.isPlaying ? "pause.fill" : "play.fill",
                                  diameter: 50) {
                    controller.togglePlay()
                }
                StudioRoundButton(systemImage: "goforward.10", diameter: 38, filled: false) {
                    controller.skip(by: 10)
                }
                Spacer()
            }
            Text("\(LibraryView.formatDuration(controller.position)) / \(LibraryView.formatDuration(song.duration))")
                .font(.caption)
                .foregroundStyle(.secondary)
            StudioSegmented(
                items: PlaybackController.speedPresets.map { (preset: Float) in (preset, "\(preset, specifier: "%g")x") },
                selection: $controller.speed)
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    /// Waveform tap: hard seek; disarms the loop when the target is
    /// outside it (PLAN §9).
    private func hardSeek(_ time: Double) {
        if controller.loopOn, let loop = controller.selectedLoop,
           time < loop.start || time > loop.end {
            controller.toggleLoopOn()
        }
        controller.seek(to: time)
        if !controller.isPlaying { controller.play() }
    }
}

/// A–B tab: pending marks with steppers, creation, and the selected
/// loop's editor (PLAN §10).
struct ABTabView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var controller: PlaybackController
    let song: Song

    var body: some View {
        List {
            Section("Mark a section") {
                markRow(title: "A", value: controller.pendingA, edge: .start) { controller.setA() }
                markRow(title: "B", value: controller.pendingB, edge: .end) { controller.setB() }
                if controller.pendingA != nil || controller.pendingB != nil {
                    Button("Clear marks") { controller.clearPendingMarks() }
                }
                Text("Set A and B at the playhead (in any order). The loop is created when both are set; if B is before A they swap automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let loop = controller.selectedLoop {
                Section("Selected loop") {
                    LoopEditorView(song: song, loop: loop)
                }
            }
        }
        .studioList()
    }

    @ViewBuilder
    private func markRow(title: String, value: Double?, edge: PlaybackController.Edge, action: @escaping () -> Void) -> some View {
        HStack {
            Button("Set \(title)") { action() }
                .buttonStyle(.bordered)
            Text(value.map { LibraryView.formatDuration($0) } ?? "—")
                .foregroundStyle(.secondary)
            Spacer()
            Button("−0.1") { controller.nudgePending(edge: edge, by: -0.1) }
                .buttonStyle(.bordered)
                .disabled(value == nil)
            Button("+0.1") { controller.nudgePending(edge: edge, by: 0.1) }
                .buttonStyle(.bordered)
                .disabled(value == nil)
        }
    }
}

/// More tab: fine speed slider + loops backup (PLAN §10).
struct MoreTabView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var controller: PlaybackController
    let song: Song
    @State private var showImporter = false
    @State private var confirmImport = false
    @State private var pendingImportData: Data?
    @State private var importFailed = false

    var body: some View {
        List {
            Section("Speed") {
                HStack {
                    Text("Fine speed")
                    Spacer()
                    Text("\(Int((controller.speed * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $controller.speed, in: 0.10...1.00, step: 0.01)
                    .tint(Studio.accent)
                Text("Presets: 25% · 50% · 75% · 100% (on the transport bar). Pitch never changes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Loops backup") {
                if let data = controller.backupJSON() {
                    ShareLink(item: BackupDocument(data: data),
                              preview: SharePreview("\(song.title) loops")) {
                        Label("Export loops…", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Import loops…", systemImage: "square.and.arrow.down")
                }
                Text("Import replaces all loops and groups for this song.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .studioList()
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    pendingImportData = data
                    confirmImport = true
                } else {
                    importFailed = true
                }
            }
        }
        .confirmationDialog("Replace all loops for this song with the imported set?",
                            isPresented: $confirmImport, titleVisibility: .visible) {
            Button("Replace loops", role: .destructive) {
                if let data = pendingImportData,
                   !controller.importBackup(data: data, context: modelContext) {
                    importFailed = true
                }
                pendingImportData = nil
            }
            Button("Cancel", role: .cancel) { pendingImportData = nil }
        }
        .alert("Import failed", isPresented: $importFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That file is not a valid RagaMentor loops backup.")
        }
    }
}
