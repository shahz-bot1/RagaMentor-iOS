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
    /// The note editor's floating-bar channel (v1.5.41): the
    /// loops tab's note field registers here while it has focus;
    /// this page renders the bar in its bottom inset.
    @State private var noteSession = NoteEditSession()

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
                                        LoopsView(song: song, noteSession: noteSession) { tab = .ab }
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
                    // Dragging the page puts the keyboard away
                    // (v1.5.41): the note field's blur save
                    // commits, like every other focus loss.
                    .scrollDismissesKeyboard(.interactively)
                }
                // The note editor's floating action bar
                // (v1.5.41): an app-drawn rounded container in
                // the bottom inset, riding the keyboard, shown
                // only while a loop note is being edited. It
                // replaces the system keyboard accessory, whose
                // square full-width container clashes with the
                // keyboard's rounded floating slab (his report).
                // The inset hangs off the ZStack — inside the
                // geometry reader — so the waveform's measured
                // height never jumps when the bar comes and goes.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if noteSession.isEditing {
                        NoteEditBar(session: noteSession)
                    }
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

/// The floating Cancel/Done container shown above the keyboard
/// while a loop note is edited (v1.5.41, his design): a rounded
/// panel in the app's colours, inset like the keyboard's own
/// floating slab. The actions arrive from the note field through
/// the session — Done unfocuses (the field's blur save commits);
/// Cancel restores the saved note first, so nothing writes.
private struct NoteEditBar: View {
    let session: NoteEditSession

    var body: some View {
        HStack {
            Button("Cancel") { session.cancel?() }
                .foregroundStyle(Studio.accent)
            Spacer()
            Button("Done") { session.done?() }
                .fontWeight(.semibold)
                .foregroundStyle(Studio.accent)
        }
        .font(.body)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Studio.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Studio.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 4)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

/// The waveform + window controls. The live slice follows the
/// playhead ONLY while this area is on screen and the song is
/// playing (v1.5.29 — Shahzin's scoping rule: subscribe only
/// when required). Paused, covered, another tab or backgrounded,
/// the live leaf unmounts and a static slice renders from the
/// plain position value; a swara pass or an interruption pauses
/// the song through the funnel, which detaches the listener by
/// construction.
struct FullscreenWaveformArea: View {
    @EnvironmentObject private var controller: PlaybackController
    let song: Song
    var height: CGFloat = 200

    @State private var peaks: [Float] = []
    @State private var window = WaveformWindow(duration: 1)
    @State private var follow = true
    /// On-screen state for the lifecycle gate.
    @State private var visible = false
    @Environment(\.scenePhase) private var scenePhase

    /// The playhead listener is mounted only while all three
    /// hold: page visible, app in the foreground, song playing.
    private var listening: Bool {
        visible && scenePhase == .active && controller.isPlaying
    }

    private var regions: [WaveRegion] {
        WaveformRegions.build(
            song: song,
            selectedLoopID: controller.selectedLoopID,
            selectedGroupID: controller.selectedGroupID)
    }
    /// The range the window was last fitted to by a selection or
    /// the badge (v1.5.21). While that exact range stays armed,
    /// follow holds the fitted view instead of paging it — the
    /// two writers (fit, follow) no longer fight. Released by a
    /// manual pan/zoom, the Fit button, disarming, a seek
    /// outside the range, or a song change.
    @State private var fittedRange: (start: Double, end: Double)?

    /// The fitted range, while it is still the armed one.
    private var activeHoldRange: (start: Double, end: Double)? {
        guard controller.loopOn, let fittedRange,
              let armed = controller.armedLoopRange,
              armed.start == fittedRange.start,
              armed.end == fittedRange.end
        else { return nil }
        return fittedRange
    }

    /// The armed loop's name, else the armed group's (web badge).
    private var armedName: String? {
        if let loop = controller.selectedLoop { return loop.name }
        if let id = controller.selectedGroupID {
            return song.groups.first { $0.id == id }?.name
        }
        return nil
    }

    var body: some View {
        Group {
            if listening {
                LiveWaveform(playhead: controller.playhead,
                             peaks: peaks,
                             duration: song.duration,
                             regions: regions,
                             window: $window,
                             follow: follow,
                             isPlaying: controller.isPlaying,
                             holdRange: activeHoldRange,
                             onSeek: hardSeek,
                             onManualWindowChange: { fittedRange = nil })
            } else {
                StaticWaveform(peaks: peaks,
                               duration: song.duration,
                               regions: regions,
                               window: $window,
                               position: controller.position,
                               onSeek: hardSeek,
                               onManualWindowChange: { fittedRange = nil })
            }
        }
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
                    fittedRange = nil
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
            .task(id: song.id) {
                window = WaveformWindow(duration: song.duration)
                fittedRange = nil
                peaks = await SongPeaks.peaks(for: song)
                // Land fitted to the armed loop/group
                // (v1.5.40): applied here, after the reset and
                // inside the same task, so no ordering can lose
                // it — the onAppear zoom replay raced this
                // reset and the page came back at full-song
                // zoom on device (his report).
                if let range = controller.armedRange(for: song.id) {
                    window = window.fitting(from: range.start, to: range.end)
                    fittedRange = range
                }
            }
            .onChange(of: controller.zoomRequest) {
                // Fit-on-select (v1.5.12): a loop or group was
                // tapped — zoom the wave to it, as large as
                // possible, centred.
                if let request = controller.zoomRequest {
                    window = window.fitting(from: request.start, to: request.end)
                    fittedRange = (request.start, request.end)
                }
            }
            .onAppear {
                visible = true
                // Restore the armed view on (re)entry (v1.5.32):
                // the loop/group kept playing while the page was
                // away — come back fitted to it.
                controller.replayArmedZoom(for: song.id)
            }
            .onDisappear { visible = false }
    }

    /// The time badge format: m:ss.t (web fmt).
    static func fmtTenths(_ t: Double) -> String {
        let total = max(0, t)
        let minutes = Int(total) / 60
        let seconds = total - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, seconds)
    }

    /// The loop badge tap: restart the armed loop/group (web),
    /// and hold the fitted view of its range — the same view a
    /// tap on the loop pill gives (v1.5.20, Shahzin's steer:
    /// the badge must not displace the waveform).
    private func restartArmed() {
        guard let range = controller.armedLoopRange else { return }
        controller.seek(to: range.start)
        window = window.fitting(from: range.start, to: range.end)
        fittedRange = range
    }

    /// Waveform tap: hard seek; disarms the loop when the target is
    /// outside it (PLAN §9).
    private func hardSeek(_ time: Double) {
        if controller.loopOn, let range = controller.armedLoopRange,
           time < range.start || time > range.end {
            controller.toggleLoopOn()
            fittedRange = nil
        }
        controller.seek(to: time)
        if !controller.isPlaying { controller.play() }
    }
}

/// The tick-driven slice of the waveform area (v1.5.27): the
/// ONLY view that observes the playhead clock, so the ~20 Hz
/// position stream re-renders this leaf alone — the peaks canvas
/// inside WaveformView keeps still inputs (peaks / window /
/// regions) and is not redrawn per tick, and the page around it
/// never sees the stream at all. Before the split, the shared
/// controller published position and every subscriber rebuilt
/// per tick, which made scrolling during playback stutter.
private struct LiveWaveform: View {
    @ObservedObject var playhead: PlayheadClock
    let peaks: [Float]
    let duration: Double
    let regions: [WaveRegion]
    @Binding var window: WaveformWindow
    let follow: Bool
    let isPlaying: Bool
    let holdRange: (start: Double, end: Double)?
    let onSeek: (Double) -> Void
    let onManualWindowChange: () -> Void

    var body: some View {
        ZStack {
            WaveformView(peaks: peaks,
                         duration: duration,
                         regions: regions,
                         window: $window,
                         zoomPanEnabled: true,
                         onSeek: onSeek,
                         onManualWindowChange: onManualWindowChange)
            PlayheadLine(window: window, position: playhead.position)
        }
        .overlay(alignment: .bottom) {
            WaveformTimeBadge(position: playhead.position, duration: duration)
        }
        .onChange(of: playhead.position) {
            // Follow (the on-wave toggle, lower left): keep the
            // playhead in view while playing — except while a
            // fitted loop/group stays armed, where the fitted
            // view is held (v1.5.21).
            if follow && isPlaying {
                window = window.following(playhead.position,
                                          holdRange: holdRange)
            }
        }
    }
}

/// The "m:ss.t / m:ss.t" badge both waveform slices share.
private struct WaveformTimeBadge: View {
    let position: Double
    let duration: Double

    var body: some View {
        Text("\(FullscreenWaveformArea.fmtTenths(position)) / \(FullscreenWaveformArea.fmtTenths(duration))")
            .font(.system(size: 12))
            .monospacedDigit()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(red: 0.078, green: 0.102, blue: 0.133).opacity(0.72),
                        in: Capsule())
            .foregroundStyle(.white)
            .padding(.bottom, 8)
    }
}

/// The still slice (v1.5.29): the same canvas, playhead line and
/// badge, rendered from the PLAIN position value — no clock
/// subscription at all. Mounted whenever the live slice is not
/// (paused, page covered, another tab, app backgrounded). The
/// area re-renders it on controller events — a seek publishes
/// one action event — so the still playhead stays correct.
private struct StaticWaveform: View {
    let peaks: [Float]
    let duration: Double
    let regions: [WaveRegion]
    @Binding var window: WaveformWindow
    let position: Double
    let onSeek: (Double) -> Void
    let onManualWindowChange: () -> Void

    var body: some View {
        ZStack {
            WaveformView(peaks: peaks,
                         duration: duration,
                         regions: regions,
                         window: $window,
                         zoomPanEnabled: true,
                         onSeek: onSeek,
                         onManualWindowChange: onManualWindowChange)
            PlayheadLine(window: window, position: position)
        }
        .overlay(alignment: .bottom) {
            WaveformTimeBadge(position: position, duration: duration)
        }
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

/// The A–B Split button: its enabled state tracks the live
/// playhead (Split is valid only while the playhead sits inside
/// the loop), so it alone observes the playhead clock (v1.5.27)
/// and the rest of the A–B tab stays off the 20 Hz stream.
private struct SplitButton: View {
    @ObservedObject var playhead: PlayheadClock
    let loop: LoopRegion
    let action: () -> Void

    var body: some View {
        Button("Split", action: action)
            .disabled(!LoopRules.canSplit(loopStart: loop.start, loopEnd: loop.end,
                                           at: playhead.position))
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
            // The web's A–B page is flat: a plain hint head line,
            // then the two stepper rows (no cards) — v1.5.12.
            Group {
                if let loop = controller.selectedLoop {
                    Text("\(loop.name) · \(LibraryView.formatDuration(loop.start)) – \(LibraryView.formatDuration(loop.end))")
                } else {
                    Text("No loop selected")
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 12) {
                stepperRow(edge: .start, tag: "A")
                stepperRow(edge: .end, tag: "B")
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
                        SplitButton(playhead: controller.playhead, loop: loop) {
                            controller.splitLoop(loop, context: modelContext)
                        }
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

    /// One A/B row, flat like the web's .fsStepper: an accent
    /// tag, a 40 pt panel step square, the value centred in the
    /// middle space (tabular numbers), the other step square,
    /// and a ghost Set button 40 high.
    private func stepperRow(edge: PlaybackController.Edge, tag: String) -> some View {
        let loop = controller.selectedLoop
        let value: Double? = loop.map { edge == .start ? $0.start : $0.end }
            ?? (edge == .start ? controller.pendingA : controller.pendingB)
        return HStack(spacing: 8) {
            Text(tag)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Studio.accent)
                .frame(width: 16)
            stepButton("−", enabled: value != nil) {
                if let loop { controller.nudgeLoop(loop, edge: edge, by: -0.1, context: modelContext) }
                else { controller.nudgePending(edge: edge, by: -0.1) }
            }
            Text(value.map { LibraryView.formatDuration($0) } ?? "—")
                .font(.system(size: 14))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            stepButton("+", enabled: value != nil) {
                if let loop { controller.nudgeLoop(loop, edge: edge, by: 0.1, context: modelContext) }
                else { controller.nudgePending(edge: edge, by: 0.1) }
            }
            Button("Set") {
                if let loop {
                    controller.setLoopEdge(loop, edge: edge, at: controller.position, context: modelContext)
                } else if edge == .start { controller.setA() } else { controller.setB() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Studio.border))
        }
    }

    private func stepButton(_ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 17))
            .foregroundStyle(.primary)
            .frame(width: 40, height: 40)
            .background(Studio.panel2, in: RoundedRectangle(cornerRadius: 9))
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
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
                        set: { song.title = $0; song.updatedAt = Date() }))
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
