import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers
import RagaCore
import PersistenceKit
import DesignSystem

// Song detail (PLAN §10): waveform on top, the transport, and a
// tabbed panel (Loops / A–B / More), pushed from the library list.
// The waveform auto-follows the playhead while playing; a tap is a
// hard seek that overrides an active loop (PLAN §9).

/// The song detail screen, pushed from the library list: the
/// waveform, the transport, and the Loops / A–B / More tabs (the
/// web fullscreen player's content, as a stack page).
struct SongDetailView: View {
    let song: Song
    /// Forward a built swara editor session UP to the library,
    /// which owns the editor's navigation destination at the
    /// stack root (see LibraryView — a destination registered
    /// inside a pushed page does not push reliably).
    var onEditSwaras: ((LoopsView.EditorSession) -> Void)? = nil

    @State private var tab: Tab = .loops

    enum Tab: String, CaseIterable { case loops = "Loops", ab = "A–B", more = "More" }

    // This view deliberately holds NO playback controller: the
    // waveform and transport leaves below own the subscriptions,
    // so the 20 Hz position publish no longer rebuilds the tab
    // content (the audit's P1 fix). The library opens the song.
    var body: some View {
        GeometryReader { geo in
            let waveHeight = min(440, max(180, geo.size.height * 0.34))
            ZStack(alignment: .top) {
                // The waveform does not scroll; the page slides
                // over it.
                FullscreenWaveformArea(song: song, height: waveHeight)

                // The scroll view sits inside a thin container
                // whose hit test declines touches over the wave
                // strip while the page rests at the top, so they
                // fall through to the waveform's own controls
                // behind it (ScrollGate; v1.5.3 — his design,
                // replacing the v1.4.5–v1.5.2 forwarding layer).
                ScrollGateContainer(stripHeight: waveHeight) {
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section {
                                Group {
                                    switch tab {
                                    case .loops:
                                        LoopsView(song: song) { tab = .ab }
                                            onEditSwaras: { onEditSwaras?($0) }
                                    case .ab:
                                        ABTabView(song: song)
                                    case .more:
                                        MoreTabView(song: song)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .background(Studio.bg)
                            } header: {
                                pinnedHeader
                            }
                        }
                        .padding(.top, waveHeight)
                    }
                    // The scroll view must not paint its own
                    // background: hosted inside the gate, the
                    // default would cover the waveform behind
                    // it (v1.5.4).
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .background(Studio.bg.ignoresSafeArea())
        .navigationTitle(song.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The playback section: transport + tabs. It starts below the
    /// waveform and pins to the top once scrolled there; the tab
    /// content keeps scrolling beneath it.
    private var pinnedHeader: some View {
        VStack(spacing: 10) {
            FullscreenTransport(song: song)
            StudioSegmented(
                items: Tab.allCases.map { ($0, $0.rawValue) },
                selection: $tab)
            .padding(.horizontal)
            Divider()
        }
        .padding(.top, 10)
        .background(Studio.bg)
    }
}

/// The waveform + window controls. The only fullscreen leaf that
/// follows the playhead: it re-renders at the position rate so the
/// playhead and window stay live, and nothing else does.
struct FullscreenWaveformArea: View {
    @EnvironmentObject private var controller: PlaybackController
    let song: Song
    var height: CGFloat = 200

    @State private var peaks: [Float] = []
    @State private var window = WaveformWindow(duration: 1)
    @State private var follow = true

    /// The armed loop's name, else the armed group's (web badge).
    private var armedName: String? {
        if let loop = controller.selectedLoop { return loop.name }
        if let id = controller.selectedGroupID {
            return song.groups.first { $0.id == id }?.name
        }
        return nil
    }

    var body: some View {
        WaveformView(peaks: peaks,
                     duration: song.duration,
                     position: controller.position,
                     regions: WaveformRegions.build(
                        song: song,
                        selectedLoopID: controller.selectedLoopID,
                        selectedGroupID: controller.selectedGroupID),
                     window: $window,
                     zoomPanEnabled: true,
                     onSeek: hardSeek)
            .frame(height: height)
            .overlay(alignment: .topTrailing) {
                if let name = armedName {
                    Button {
                        restartArmed()
                    } label: {
                        Text(name)
                            .lineLimit(1)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(red: 0.078, green: 0.102, blue: 0.133).opacity(0.72),
                                        in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 240, alignment: .trailing)
                    .padding(8)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Button {
                    follow.toggle()
                } label: {
                    Image(systemName: follow ? "location.fill" : "location")
                        .font(.system(size: 13))
                        .frame(width: 30, height: 30)
                        .background(Color(red: 0.078, green: 0.102, blue: 0.133).opacity(0.72),
                                    in: Circle())
                        .foregroundStyle(follow ? Studio.accent : .white)
                }
                .buttonStyle(.plain)
                .padding(8)
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    window = WaveformWindow(duration: song.duration)
                } label: {
                    Text("Fit")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Color(red: 0.078, green: 0.102, blue: 0.133).opacity(0.72),
                                    in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(8)
            }
            .overlay(alignment: .bottom) {
                Text("\(Self.fmtTenths(controller.position)) / \(Self.fmtTenths(song.duration))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.078, green: 0.102, blue: 0.133).opacity(0.72),
                                in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 8)
            }
            .task(id: song.id) {
                window = WaveformWindow(duration: song.duration)
                peaks = await SongPeaks.peaks(for: song)
            }
            .onChange(of: controller.position) {
                // Follow (the on-wave toggle, lower left): keep the
                // playhead in view while playing.
                if follow && controller.isPlaying {
                    window = window.following(controller.position)
                }
            }
    }

    /// The time badge format: m:ss.t (web fmt).
    static func fmtTenths(_ t: Double) -> String {
        let total = max(0, t)
        let minutes = Int(total) / 60
        let seconds = total - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, seconds)
    }

    /// The loop badge tap: restart the armed loop/group (web).
    private func restartArmed() {
        guard let range = controller.armedLoopRange else { return }
        controller.seek(to: range.start)
    }

    /// Waveform tap: hard seek; disarms the loop when the target is
    /// outside it (PLAN §9).
    private func hardSeek(_ time: Double) {
        if controller.loopOn, let range = controller.armedLoopRange,
           time < range.start || time > range.end {
            controller.toggleLoopOn()
        }
        controller.seek(to: time)
        if !controller.isPlaying { controller.play() }
    }
}

/// The persistent mini-transport (skip, play/pause, time, speed).
struct FullscreenTransport: View {
    @EnvironmentObject private var controller: PlaybackController
    let song: Song

    var body: some View {
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
            StudioSegmented(
                items: PlaybackController.speedPresets.map { (preset: Float) in (preset, String(format: "%gx", preset)) },
                selection: $controller.speed)
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }
}

/// A–B tab (web #fsPageAB): a head line, the A and B stepper rows
/// (tag, −, value, +, Set), the Loop toggle + Split row, and the
/// add-loop row. With a loop selected the steppers and Set write
/// into that loop's edges; without one they work on the pending
/// marks.
struct ABTabView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var controller: PlaybackController
    let song: Song
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 14) {
            StudioCard {
                if let loop = controller.selectedLoop {
                    Text("\(loop.name) · \(LibraryView.formatDuration(loop.start)) – \(LibraryView.formatDuration(loop.end))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No loop selected")
                        .foregroundStyle(.secondary)
                }
            }
            StudioCard {
                VStack(spacing: 12) {
                    stepperRow(edge: .start, tag: "A")
                    Divider()
                    stepperRow(edge: .end, tag: "B")
                }
            }
            if let loop = controller.selectedLoop {
                StudioCard {
                    HStack {
                        Button {
                            controller.toggleLoopOn()
                        } label: {
                            Text("Loop")
                                .foregroundStyle(controller.loopOn ? Studio.accent : .primary)
                        }
                        Spacer()
                        Button {
                            controller.splitLoop(loop, context: modelContext)
                        } label: {
                            Text("Split")
                        }
                        .disabled(!LoopRules.canSplit(loopStart: loop.start, loopEnd: loop.end,
                                                       at: controller.position))
                    }
                }
            }
            StudioCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Loop name (optional)", text: $newName)
                        Button("＋ Add loop") { addFromMarks() }
                            .disabled(controller.pendingA == nil || controller.pendingB == nil)
                    }
                    if controller.pendingA != nil || controller.pendingB != nil {
                        Button("Clear marks") { controller.clearPendingMarks() }
                    }
                }
            }
        }
        .padding(16)
    }

    private func stepperRow(edge: PlaybackController.Edge, tag: String) -> some View {
        let loop = controller.selectedLoop
        let value: Double? = loop.map { edge == .start ? $0.start : $0.end }
            ?? (edge == .start ? controller.pendingA : controller.pendingB)
        return HStack {
            Text(tag).font(.headline).frame(width: 18)
            Button("−") {
                if let loop { controller.nudgeLoop(loop, edge: edge, by: -0.1, context: modelContext) }
                else { controller.nudgePending(edge: edge, by: -0.1) }
            }
            .buttonStyle(.bordered)
            .disabled(value == nil)
            Text(value.map { LibraryView.formatDuration($0) } ?? "—")
                .frame(minWidth: 52)
                .foregroundStyle(.secondary)
            Button("+") {
                if let loop { controller.nudgeLoop(loop, edge: edge, by: 0.1, context: modelContext) }
                else { controller.nudgePending(edge: edge, by: 0.1) }
            }
            .buttonStyle(.bordered)
            .disabled(value == nil)
            Spacer()
            Button("Set") {
                if let loop {
                    controller.setLoopEdge(loop, edge: edge, at: controller.position, context: modelContext)
                } else if edge == .start { controller.setA() } else { controller.setB() }
            }
            .buttonStyle(.bordered)
        }
    }

    private func addFromMarks() {
        guard let a = controller.pendingA, let b = controller.pendingB else { return }
        controller.clearPendingMarks()
        if let loop = controller.createLoop(start: a, end: b, context: modelContext) {
            let name = newName.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                controller.renameLoop(loop, to: name, context: modelContext)
            }
        }
        newName = ""
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
        VStack(spacing: 14) {
            StudioCard {
                VStack(alignment: .leading, spacing: 8) {
                    StudioSectionTitle("Song")
                    TextField("Song title", text: Binding(
                        get: { song.title },
                        set: { song.title = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
            }
            StudioCard {
                VStack(alignment: .leading, spacing: 8) {
                    StudioSectionTitle("Speed")
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
            }
            StudioCard {
                VStack(alignment: .leading, spacing: 10) {
                    StudioSectionTitle("Loops backup")
                    if let data = controller.backupJSON() {
                        ShareLink(item: BackupDocument(data: data),
                                  preview: SharePreview("\(song.title) loops")) {
                            Text("Export loops…")
                        }
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Text("Import loops…")
                    }
                    Text("Import replaces all loops and groups for this song.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
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
