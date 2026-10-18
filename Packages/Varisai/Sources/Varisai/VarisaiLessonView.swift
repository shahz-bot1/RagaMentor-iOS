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
                playRow
                patternsCard
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
            }
        }
    }

    /// The play row under the big Play button (web .playrow): the
    /// Loop toggle as a button, on-state tinted.
    private var playRow: some View {
        HStack(spacing: 10) {
            Button {
                loopOn.toggle()
            } label: {
                Text("🔁 Loop")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(loopOn ? Studio.accentSoft : Studio.panel2,
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(loopOn ? Studio.accent : Studio.border, lineWidth: 1))
                    .foregroundStyle(Studio.text)
            }
            .buttonStyle(.plain)
        }
    }

    /// The Patterns card (web's second card): every pattern in the
    /// lesson, the current one marked; a tap jumps to it.
    private var patternsCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 8) {
                StudioSectionTitle("Patterns")
                Text("\(lesson.patterns.count) patterns")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(lesson.patterns.indices, id: \.self) { i in
                    Button {
                        patternIndex = i
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(lesson.patterns[i].title)
                                    .font(.callout.weight(i == patternIndex ? .semibold : .regular))
                                    .foregroundStyle(i == patternIndex ? Studio.accent : Studio.text)
                                if !lesson.patterns[i].sub.isEmpty {
                                    Text(lesson.patterns[i].sub)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if i == patternIndex {
                                Text("●").font(.caption).foregroundStyle(Studio.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < lesson.patterns.count - 1 {
                        Divider()
                    }
                }
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
///
/// Layout is the web's flex model exactly: each line fills the
/// container width; a group takes a share proportional to its
/// token count, so EVERY token cell on a line has the same width —
/// (container − gaps) / tokens in the line.
struct VarisaiGridView: View {
    @ObservedObject var player: VarisaiPlayer
    let lines: [[[(token: String, index: Int)]]]
    let full: Bool

    var body: some View {
        let current = player.isPlaying ? player.currentToken : -1
        VStack(alignment: .leading, spacing: 10) {
            ForEach(lines.indices, id: \.self) { lineIndex in
                lineView(lines[lineIndex], current: current)
            }
        }
    }

    private func lineView(_ line: [[(token: String, index: Int)]],
                          current: Int) -> some View {
        let total = max(1, line.reduce(0) { $0 + $1.count })
        return GeometryReader { geo in
            let gap: CGFloat = 8
            let unit = (geo.size.width - gap * CGFloat(max(0, line.count - 1)))
                / CGFloat(total)
            HStack(spacing: gap) {
                ForEach(line.indices, id: \.self) { groupIndex in
                    groupView(line[groupIndex],
                              width: unit * CGFloat(line[groupIndex].count),
                              current: current)
                }
            }
        }
        .frame(height: 40)
    }

    @ViewBuilder
    private func groupView(_ group: [(token: String, index: Int)],
                           width: CGFloat, current: Int) -> some View {
        if group.count == 1, VarisaiToken.isRest(group[0].token) {
            // A lone rest/hold group: a bare chip with one token's
            // share of the line (web: flex 1 1 0, no group box).
            Text(VarisaiToken.label(group[0].token, full: full))
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .frame(width: width, height: 40)
        } else {
            HStack(spacing: 2) {
                ForEach(group, id: \.index) { item in
                    VarisaiTokenCell(
                        text: VarisaiToken.label(item.token, full: full),
                        isCurrent: item.index == current,
                        isLow: item.token.hasPrefix(",") && item.token != ",")
                        .equatable()
                }
            }
            .padding(4)
            .frame(width: width, height: 40)
            .background(Studio.panel2, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Studio.border, lineWidth: 1))
        }
    }
}

/// One notation token. Equatable, so SwiftUI skips re-rendering
/// every cell whose highlight state did not change. Cells share
/// their group equally (web: flex 1 1 0) at the web's 13.5 pt size.
struct VarisaiTokenCell: View, Equatable {
    let text: String
    let isCurrent: Bool
    let isLow: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 13.5, weight: .medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isCurrent ? Studio.accent : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isLow && !isCurrent ? Studio.muted.opacity(0.4)
                                                      : Color.clear,
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            )
            .foregroundStyle(isCurrent ? .white : Studio.text)
    }
}
