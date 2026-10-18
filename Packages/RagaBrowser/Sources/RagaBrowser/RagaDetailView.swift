import SwiftUI
import RagaCore
import AudioKit
import DesignSystem

/// One raga's detail (web raga detail): the scale with its notation
/// toggle, the Listen card (Sa, tempo, one Play for arohana +
/// avarohana, test beep and status), the v14 display piano, allied
/// ragas and the Lakshana placeholder. In pick mode a "✓ Use this
/// raga" button applies the raga to the calling editor.
struct RagaDetailView: View {
    let raga: Raga
    let library: any RagaLibrary
    @ObservedObject var player: ScalePlayer
    var onPick: ((Raga) -> Void)?

    @AppStorage("raga-sa") private var saOffset = 0
    @AppStorage("raga-tempo") private var tempo = 120
    @AppStorage("raga-label-mode") private var labelMode = "sargam"
    @State private var notation: Notation
    @State private var status = "Audio: not started — tap Test beep below"
    @State private var isFavourite: Bool
    @State private var tempoToken = 0
    /// Cross-studio audio focus registration (P6).
    @EnvironmentObject private var audioFocus: StudioAudioFocus
    @State private var focusToken: UUID?

    private enum Notation: Hashable { case carnatic, hindustani }

    init(raga: Raga, library: any RagaLibrary, player: ScalePlayer,
         onPick: ((Raga) -> Void)?) {
        self.raga = raga
        self.library = library
        self.player = player
        self.onPick = onPick
        self._notation = State(initialValue: raga.isHindustani ? .hindustani : .carnatic)
        self._isFavourite = State(initialValue: library.isFavourite(sourceId: raga.id))
    }

    private var walk: [ScaleWalk.Note] {
        ScaleWalk.notes(aro: raga.aro, ava: raga.ava)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let onPick {
                    Button {
                        onPick(raga)
                    } label: {
                        Text("✓ Use this raga")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(StudioPrimaryButtonStyle())
                }
                scaleCard
                listenCard
                pianoCard
                alliedCard
                lakshanaCard
            }
            .padding(16)
        }
        .background(Studio.bg.ignoresSafeArea())
        .navigationTitle(raga.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            focusToken = audioFocus.register { player.stop() }
        }
        .onDisappear {
            player.stop()
            if let focusToken { audioFocus.unregister(focusToken) }
        }
        .onChange(of: tempo) { _, newTempo in
            // Web: a tempo change while playing restarts after a
            // 350 ms debounce.
            guard player.isPlaying else { return }
            tempoToken += 1
            let token = tempoToken
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                if token == tempoToken, player.isPlaying {
                    play(newTempo)
                }
            }
        }
        .onChange(of: saOffset) { _, _ in
            if player.isPlaying { play(tempo) }
        }
    }

    // MARK: - Cards

    private var scaleCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(raga.name).font(.title3.weight(.semibold))
                        Text(metaLine).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        isFavourite.toggle()
                        library.setFavourite(raga, favourited: isFavourite)
                    } label: {
                        Image(systemName: isFavourite ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(isFavourite ? Studio.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                StudioSegmented(items: [(Notation.carnatic, "Carnatic"),
                                        (.hindustani, "Hindustani")],
                                selection: $notation)
                scaleLine(label: "Arohana", tokens: raga.aro)
                scaleLine(label: "Avarohana", tokens: raga.ava)
            }
        }
    }

    private func scaleLine(label: String, tokens: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(tokens.map(display).joined(separator: " "))
                .font(.body)
        }
    }

    private func display(_ token: String) -> String {
        guard notation == .hindustani else { return token }
        if token.hasSuffix("'") || token.hasSuffix("′") {
            return ScaleNotation.hindustani(String(token.dropLast())) + "′"
        }
        return ScaleNotation.hindustani(token)
    }

    private var listenCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    StudioSectionTitle("Listen · harmonium")
                    Text("v14").font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Studio.panel2, in: Capsule())
                        .foregroundStyle(.secondary)
                }
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
                    Text("Tempo").foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(tempo) },
                        set: { tempo = Int($0) }),
                        in: 30...240, step: 10)
                        .tint(Studio.accent)
                    Text("\(tempo) bpm").font(.callout).monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                Button {
                    if player.isPlaying { player.stop() } else { play(tempo) }
                } label: {
                    Text(player.isPlaying ? "■ Stop" : "▶ Play")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(StudioPrimaryButtonStyle())
                HStack(spacing: 10) {
                    Button("🔔 Test beep") {
                        player.beep()
                        status = "Audio: running — beep playing…"
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Text("🔇 No sound on iPhone? Turn off silent mode.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Harmonium: tonejs-instruments · CC-BY 3.0 · Choir: Sonatina · CC Sampling+ 1.0 · AI voice: DiffSinger TIGER (experimental, non-commercial voicebank)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var pianoCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    StudioSectionTitle("Piano")
                    Spacer()
                    StudioSegmented(items: [("sargam", "Sargam"), ("western", "Western")],
                                    selection: $labelMode)
                        .frame(width: 190)
                }
                PianoView(
                    saPitchClass: saOffset,
                    scalePitchClasses: ScaleWalk.pitchClasses(aro: raga.aro, ava: raga.ava),
                    highlightRel: player.currentIndex >= 0 && player.currentIndex < walk.count
                        ? walk[player.currentIndex].semitone : nil,
                    westernLabels: labelMode == "western")
            }
        }
    }

    private var alliedCard: some View {
        let resolved = raga.allied.compactMap { name in
            RagaCatalog.all.first { $0.name == name }
        }
        return Group {
            if !resolved.isEmpty {
                StudioCard {
                    VStack(alignment: .leading, spacing: 10) {
                        StudioSectionTitle("Allied ragas · sounds like")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)],
                                  alignment: .leading, spacing: 8) {
                            ForEach(resolved, id: \.id) { allied in
                                NavigationLink(value: allied.id) {
                                    StudioChipLabel(title: allied.name)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var lakshanaCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 6) {
                StudioSectionTitle("Lakshana · curated in v1")
                Text("Vadi / samvadi, anya swaras, jeeva swaras and compositions land here once the dataset is curated.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Playback

    private func play(_ atTempo: Int) {
        audioFocus.stopAll(except: focusToken)
        player.play(semitones: walk.map { $0.semitone + saOffset },
                    tempo: atTempo)
        status = "Audio: ready · harmonium"
    }

    private var metaLine: String {
        if let n = raga.melakartaNumber {
            return "Melakarta \(n) · Chakra \(Melakarta.chakraName(forNumber: n)) · \(raga.jati ?? "")"
        }
        if let parent = raga.parentMelakarta {
            return "Janya of \(parent) · \(raga.jati ?? "")"
        }
        if let thaat = raga.thaat {
            return "Hindustani · Thaat \(thaat) · \(raga.jati ?? "")"
        }
        return raga.jati ?? ""
    }
}

/// A non-interactive chip look for navigation links (StudioChip is
/// a button; allied pills are links).
private struct StudioChipLabel: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Studio.panel2, in: Capsule())
            .overlay(Capsule().strokeBorder(Studio.border, lineWidth: 1))
            .foregroundStyle(Studio.text)
    }
}
