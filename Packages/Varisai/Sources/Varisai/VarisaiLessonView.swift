import SwiftUI
import RagaCore
import AudioKit
import DesignSystem

/// One lesson's practice screen (web varisai player): pattern
/// prev/select/next, the grouped notation grid with per-token
/// highlight, the laya line or tappable tala box, and the controls
/// — Sa, speed, labels, the shared tempo slider (30–90, steps of
/// 10), the loop toggle and the big Play button.
struct VarisaiLessonView: View {
    let lesson: VarisaiLesson
    let onPlayStart: () -> Void

    @StateObject private var player = VarisaiPlayer()
    @State private var patternIndex = 0
    /// The pattern's display lines with flat playback indices,
    /// rebuilt only when the pattern changes — never per highlight
    /// tick (the grid re-renders at up to 12 ticks/second).
    @State private var indexedLines: [[[(token: String, index: Int)]]] = []
    @State private var loopOn = true
    @State private var showTalaLegend = false
    @State private var tempoToken = 0
    /// Cross-studio audio focus registration (P6).
    @EnvironmentObject private var audioFocus: StudioAudioFocus
    @State private var focusToken: UUID?

    @AppStorage("varisai-sa") private var saOffset = 0
    @AppStorage("varisai-tempo") private var tempo = 60
    @AppStorage("varisai-speed") private var speed = "2"
    @AppStorage("varisai-labels") private var labels = "simple"

    private var pattern: VarisaiPattern { lesson.patterns[patternIndex] }
    private var speedValue: Int { Int(speed) ?? 2 }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                patternHeader
                VarisaiGridView(player: player, lines: indexedLines,
                                full: labels == "full")
                controlsCard
                playButton
            }
            .padding(16)
        }
        .background(Studio.bg.ignoresSafeArea())
        .navigationTitle(lesson.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            focusToken = audioFocus.register { player.stop() }
            rebuildLines()
        }
        .onDisappear {
            player.stop()
            if let focusToken { audioFocus.unregister(focusToken) }
        }
        .onChange(of: loopOn) { _, newValue in
            // The player reads the toggle live at the loop seam.
            player.loopEnabled = newValue
        }
        .onChange(of: patternIndex) { _, _ in
            player.stop()
            rebuildLines()
        }
        .onChange(of: saOffset) { _, _ in restartIfPlaying(debounced: false) }
        .onChange(of: speed) { _, _ in restartIfPlaying(debounced: false) }
        .onChange(of: labels) { _, _ in player.stop() }
        .onChange(of: tempo) { _, _ in restartIfPlaying(debounced: true) }
    }

    // MARK: - Header & grid

    private var patternHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Button { patternIndex -= 1 } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(patternIndex == 0)
                Spacer()
                Menu {
                    ForEach(lesson.patterns.indices, id: \.self) { i in
                        Button(lesson.patterns[i].title) { patternIndex = i }
                    }
                } label: {
                    VStack(spacing: 1) {
                        Text(pattern.title).font(.headline)
                            .foregroundStyle(Studio.text)
                        Text(pattern.sub).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { patternIndex += 1 } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(patternIndex == lesson.patterns.count - 1)
            }
            if let laya = pattern.laya {
                Text("Laya · \(laya)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let tala = pattern.tala {
                Button {
                    showTalaLegend = true
                } label: {
                    Text("Tala · \(tala) · \(VarisaiPlayback.talaBeats(tala)) beats")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Studio.panel2, in: Capsule())
                        .foregroundStyle(Studio.text)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showTalaLegend) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tala angas").font(.headline)
                        Text("I‹n› — Laghu, n beats")
                        Text("0 — Drutam, 2 beats")
                        Text("U — Anudrutam, 1 beat")
                        Text("This pattern: \(tala) = \(VarisaiPlayback.talaBeats(tala)) beats per cycle.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(16)
                    .presentationCompactAdaptation(.popover)
                }
            }
        }
    }

    /// Rebuild the cached display lines for the current pattern.
    private func rebuildLines() {
        var next = -1
        indexedLines = pattern.dlines.map { line in
            line.map { group in
                group.map { token in
                    next += 1
                    return (token: token, index: next)
                }
            }
        }
    }

    // MARK: - Controls & play

    private var controlsCard: some View {
        StudioCard {
            VStack(spacing: 12) {
                HStack {
                    Text("Sa").foregroundStyle(.secondary)
                    Spacer()
                    Picker("Sa", selection: $saOffset) {
                        ForEach(0..<12, id: \.self) { i in
                            Text(Swara.saNames[i]).tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                }
                HStack {
                    Text("Speed").foregroundStyle(.secondary)
                    Spacer()
                    StudioSegmented(items: [("1", "1x"), ("2", "2x"),
                                            ("4", "4x"), ("8", "8x")],
                                    selection: $speed)
                        .frame(width: 190)
                }
                HStack {
                    Text("Labels").foregroundStyle(.secondary)
                    Spacer()
                    StudioSegmented(items: [("simple", "Simple"), ("full", "Full")],
                                    selection: $labels)
                        .frame(width: 190)
                }
                HStack {
                    Text("Tempo").foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(tempo) },
                        set: { tempo = Int($0) }),
                        in: 30...90, step: 10)
                        .tint(Studio.accent)
                    Text("\(tempo) bpm").font(.callout).monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                Toggle("Loop", isOn: $loopOn)
            }
        }
    }

    private var playButton: some View {
        Button {
            if player.state == .idle {
                onPlayStart()
                start()
            } else {
                player.stop()
            }
        } label: {
            Text(player.state == .playing ? "■ Stop"
                 : player.state == .loading ? "⏳ Loading…" : "▶ Play pattern")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(player.state == .playing
                            ? Color(red: 0.878, green: 0.322, blue: 0.322)
                            : Studio.accent,
                            in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Playback control

    private func start() {
        audioFocus.stopAll(except: focusToken)
        player.play(pattern: pattern, saOffset: saOffset, tempo: tempo,
                    speed: speedValue, loop: loopOn)
    }

    /// Web restart rules: Sa and speed restart at once; tempo
    /// restarts after a 350 ms debounce; labels only re-render.
    private func restartIfPlaying(debounced: Bool) {
        guard player.state == .playing else { return }
        if !debounced {
            start()
            return
        }
        tempoToken += 1
        let token = tempoToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if token == tempoToken, player.state == .playing {
                start()
            }
        }
    }
}

/// The notation grid, isolated from the lesson screen: it alone
/// observes the player's per-token highlight, so a highlight tick
/// re-renders only the grid — the header's pattern menu and the
/// controls stay untouched while playing (they used to rebuild on
/// every tick, which starved the highlight and flickered the menu).
struct VarisaiGridView: View {
    @ObservedObject var player: VarisaiPlayer
    let lines: [[[(token: String, index: Int)]]]
    let full: Bool

    var body: some View {
        let current = player.isPlaying ? player.currentToken : -1
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines.indices, id: \.self) { lineIndex in
                HStack(spacing: 6) {
                    ForEach(lines[lineIndex].indices, id: \.self) { groupIndex in
                        HStack(spacing: 3) {
                            ForEach(lines[lineIndex][groupIndex], id: \.index) { item in
                                VarisaiTokenCell(
                                    text: VarisaiToken.label(item.token, full: full),
                                    isCurrent: item.index == current)
                                    .equatable()
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(Studio.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Studio.border, lineWidth: 1))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// One notation token. Equatable, so SwiftUI skips re-rendering
/// every cell whose highlight state did not change.
struct VarisaiTokenCell: View, Equatable {
    let text: String
    let isCurrent: Bool

    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(isCurrent ? Studio.accent : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(isCurrent ? .white : Studio.text)
    }
}
