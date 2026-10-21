import SwiftUI
import RagaCore
import AudioKit
import DesignSystem

/// One lesson's practice screen (web varisai player, web
/// order): pattern prev/select/next, the laya line or tappable
/// tala box, the grouped notation grid with per-token highlight,
/// and the floating playback card — Sa, speed, labels, the
/// shared tempo slider (30–90, steps of 10), the loop toggle
/// and the big Play button.
struct VarisaiLessonView: View {
    let lesson: VarisaiLesson
    let onPlayStart: () -> Void
    /// The app's one shared sequence player (P-E).
    let sequencePlayer: SequencePlayer

    /// The adapter lives in a plain box the lesson view does NOT
    /// observe: only the grid and the play button subscribe to
    /// its SequencePlayer, so a highlight tick never rebuilds
    /// this screen (the pattern menu flickered while the whole
    /// screen was subscribed).
    @State private var adapterBox: VarisaiAdapterBox
    private var adapter: VarisaiAdapter { adapterBox.adapter }

    init(lesson: VarisaiLesson, onPlayStart: @escaping () -> Void,
         sequencePlayer: SequencePlayer) {
        self.lesson = lesson
        self.onPlayStart = onPlayStart
        self.sequencePlayer = sequencePlayer
        _adapterBox = State(initialValue: VarisaiAdapterBox(player: sequencePlayer))
    }
    @State private var patternIndex = 0
    /// The pattern's display lines with flat playback indices,
    /// rebuilt only when the pattern changes — never per highlight
    /// tick (the grid re-renders at up to 12 ticks/second).
    @State private var indexedLines: [[[(token: String, index: Int)]]] = []
    @State private var loopOn = true
    @State private var showTalaLegend = false
    @State private var tempoToken = 0
    /// Measured height of the floating playback card (with its
    /// margins), so the scroll content can clear it. The estimate
    /// is replaced by the real height on first layout.
    @State private var cardHeight: CGFloat = 225
    /// Page visibility for the grid's gate (v1.5.29).
    @State private var pageVisible = false
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
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 12) {
                    patternRow
                    metaLine
                    layaSection
                    PlaybackGate(player: adapter.player,
                                 contextKey: VarisaiAdapter.contextKey,
                                 visible: pageVisible) { _, index in
                        VarisaiGridView(lines: indexedLines,
                                        full: labels == "full",
                                        current: index)
                    }
                }
                .padding(16)
                // Clear the floating playback card: the swaras
                // scroll beneath it, and the last line can always
                // scroll clear of it.
                .padding(.bottom, cardHeight)
            }
            playbackCard
        }
        .background(Studio.bg.ignoresSafeArea())
        .navigationTitle(lesson.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            focusToken = audioFocus.register { adapter.stop() }
            rebuildLines()
            pageVisible = true
        }
        .onDisappear {
            adapter.stop()
            if let focusToken { audioFocus.unregister(focusToken) }
            pageVisible = false
        }
        .onChange(of: loopOn) { _, newValue in
            // The policy reads the toggle live at the loop seam.
            adapter.loopEnabled = newValue
        }
        .onChange(of: patternIndex) { _, _ in
            adapter.stop()
            rebuildLines()
        }
        .onChange(of: saOffset) { _, _ in restartIfPlaying(debounced: false) }
        .onChange(of: speed) { _, _ in restartIfPlaying(debounced: false) }
        .onChange(of: labels) { _, _ in adapter.stop() }
        .onChange(of: tempo) { _, _ in restartIfPlaying(debounced: true) }
    }

    // MARK: - Header & grid

    /// One compact pattern row: prev/next chevrons around the
    /// pattern name (a menu for direct jumps) and its count.
    private var patternRow: some View {
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
                    Text(pattern.title)
                        .font(.headline)
                        .foregroundStyle(Studio.text)
                    Text("Pattern \(patternIndex + 1) of \(lesson.patterns.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { patternIndex += 1 } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(patternIndex == lesson.patterns.count - 1)
        }
    }

    /// The old title/sub block as one light line: the pattern's
    /// own description, then the raga and swara count as chips.
    private var metaLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !pattern.sub.isEmpty {
                Text(pattern.sub)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                metaChip(lesson.raga)
                metaChip("\(pattern.notes.count) swaras")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metaChip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Studio.panel2, in: Capsule())
            .overlay(Capsule().strokeBorder(Studio.border, lineWidth: 1))
            .foregroundStyle(Studio.text)
    }

    /// Laya/Tala as the full boxed components, always expanded
    /// (v1.5.15 — the collapsed preview row is gone at Shahzin's
    /// call). The Tala box still taps open the anga legend.
    @ViewBuilder
    private var layaSection: some View {
        if let laya = pattern.laya {
            LayaInfoBox(title: "Laya", parts: LayaParts.parse(laya))
        }
        if let tala = pattern.tala {
            Button {
                showTalaLegend = true
            } label: {
                LayaInfoBox(
                    title: "Tala",
                    parts: [tala.split(separator: " ").map(String.init)],
                    legend: VarisaiPlayback.angaBeats(tala)
                        .map(String.init).joined(separator: " + ")
                        + " = \(VarisaiPlayback.talaBeats(tala)) beats")
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

    /// Sa / Speed / Labels: the web's three ctl-drops, carried
    /// on the playback card.
    private var settingsRow: some View {
        HStack(alignment: .top, spacing: 10) {
            ctlDrop(label: "Sa", value: Swara.saNames[saOffset]) {
                ForEach(0..<12, id: \.self) { i in
                    Button(Swara.saNames[i]) { saOffset = i }
                }
            }
            ctlDrop(label: "Speed", value: "\(speedValue)x") {
                ForEach([1, 2, 4, 8], id: \.self) { v in
                    Button("\(v)x") { speed = "\(v)" }
                }
            }
            ctlDrop(label: "Labels",
                    value: labels == "full" ? "S R₁ G₃" : "S R G") {
                Button("S R G") { labels = "simple" }
                Button("S R₁ G₃") { labels = "full" }
            }
        }
    }

    /// One web ctl-drop: a small caps label over a select-style box.
    private func ctlDrop<Items: View>(label: String, value: String,
                                      @ViewBuilder items: () -> Items) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            Menu {
                items()
            } label: {
                HStack {
                    Text(value).font(.system(size: 16))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 46)
                .background(Studio.panel2, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Studio.border, lineWidth: 1))
                .foregroundStyle(Studio.text)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The playback card, floating at the bottom like a
    /// collection accessory: Sa/Speed/Labels, the tempo row and
    /// Play/Loop, in the web's control order. The swaras scroll
    /// beneath it; the scroll content clears it by the measured
    /// cardHeight.
    private var playbackCard: some View {
        VStack(spacing: 10) {
            settingsRow
            HStack(spacing: 10) {
                Text("Tempo").foregroundStyle(Studio.text)
                Slider(value: Binding(
                    get: { Double(tempo) },
                    set: { tempo = Int($0) }),
                    in: 30...90, step: 5)
                    .tint(Studio.accent)
                Text("\(tempo) BPM").font(.callout).monospacedDigit()
                    .foregroundStyle(Studio.text)
            }
            HStack(spacing: 10) {
                playButton
                loopButton
            }
        }
        .padding(14)
        .background(Studio.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Studio.border, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { cardHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, height in
                        cardHeight = height
                    }
            }
        }
    }

    private var loopButton: some View {
        Button {
            loopOn.toggle()
        } label: {
            Text("🔁 Loop")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(loopOn ? Studio.accentSoft : Studio.panel2,
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(loopOn ? Studio.accent : Studio.border, lineWidth: 1))
                .foregroundStyle(Studio.text)
        }
        .buttonStyle(.plain)
    }

    private var playButton: some View {
        VarisaiPlayButton(player: adapter.player) {
            if adapter.state == .idle {
                onPlayStart()
                start()
            } else {
                adapter.stop()
            }
        }
    }

    // MARK: - Playback control

    private func start() {
        audioFocus.stopAll(except: focusToken)
        adapter.play(pattern: pattern, saOffset: saOffset, tempo: tempo,
                     speed: speedValue, loop: loopOn)
    }

    /// Web restart rules: Sa and speed restart at once; tempo
    /// restarts after a 350 ms debounce; labels only re-render.
    private func restartIfPlaying(debounced: Bool) {
        guard adapter.state == .playing else { return }
        if !debounced {
            start()
            return
        }
        tempoToken += 1
        let token = tempoToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if token == tempoToken, adapter.state == .playing {
                start()
            }
        }
    }
}

/// The notation grid: a pure function of its lines and the
/// current token index. It used to observe the player itself;
/// the PlaybackGate at the call site owns that subscription now
/// (v1.5.29 — subscribe only when required), so the grid
/// re-renders only while its own lesson plays on this visible
/// screen — the header's pattern menu and the controls stay
/// untouched while playing, as before.
///
/// Layout is the web's flex model exactly: each line fills the
/// container width; a group takes a share proportional to its
/// token count, so EVERY token cell on a line has the same width —
/// (container − gaps) / tokens in the line.
struct VarisaiGridView: View {
    let lines: [[[(token: String, index: Int)]]]
    let full: Bool
    /// The highlighted token index, -1 when no pass is live.
    let current: Int

    var body: some View {
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
                    SwaraTokenCell(
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

/// Holds the lesson's adapter without the lesson view
/// subscribing to it (see the lesson view's note). The adapter
/// is main-actor isolated; view state is always created on the
/// main actor, so the isolated init is assumed, not awaited.
final class VarisaiAdapterBox {
    let adapter: VarisaiAdapter
    init(player: SequencePlayer) {
        adapter = MainActor.assumeIsolated { VarisaiAdapter(player: player) }
    }
}

/// The big Play/Stop button — the only control that observes the
/// player's state, so playback state changes rebuild nothing else.
struct VarisaiPlayButton: View {
    @ObservedObject var player: SequencePlayer
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Text(player.state == .playing ? "■ Stop"
                 : player.state == .loading ? "⏳ Loading…" : "▶ Play")
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
}

/// The web's laya/tala info box (.laya): a panel2 card with a
/// small caps title and the groups as dark inset boxes, parts
/// joined by an italic "and"; the tala variant adds the beat-math
/// legend line under a divider.
struct LayaInfoBox: View {
    let title: String
    let parts: [[String]]
    var legend: String? = nil

    private struct Element: Identifiable {
        let id: Int
        let text: String?   // nil renders the italic "and"
    }

    private var elements: [Element] {
        var out: [Element] = []
        for (index, part) in parts.enumerated() {
            if index > 0 { out.append(Element(id: out.count, text: nil)) }
            for group in part {
                out.append(Element(id: out.count, text: group))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            FlowStack(items: elements, spacing: 6, rowSpacing: 6) { element in
                if let text = element.text {
                    Text(text)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Studio.bg, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Studio.border, lineWidth: 1))
                        .foregroundStyle(Studio.text)
                } else {
                    Text("and")
                        .font(.system(size: 12))
                        .italic()
                        .foregroundStyle(.secondary)
                }
            }
            if let legend {
                Divider()
                Text(legend)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Studio.panel2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Studio.border, lineWidth: 1))
    }
}
