import SwiftUI
import RagaCore
import AudioKit
import DesignSystem

/// The Listen card + piano card for a raga, as one section. It is
/// the detail page's only observer of the scale player, so the
/// per-note highlight pulse re-renders this section alone — the
/// scale, allied and lakshana cards stay still while a scale plays
/// (the audit's isolation rule).
struct RagaListenSection: View {
    let raga: Raga
    let adapter: ScaleAdapter
    /// The unified core the adapter drives; observed here so the
    /// per-note highlight pulse re-renders this section alone.
    @ObservedObject var player: SequencePlayer
    /// Piano labels use the Hindustani mapping when the detail's
    /// notation toggle is Hindustani.
    var hindustaniLabels: Bool
    /// Fired on every scale start, so the shell stops the song
    /// and any phrase — the focus registry cannot stop the song
    /// (it is never registered), which is why a raga kept playing
    /// over a LoopLab song until v1.5.14.
    var onPlayStart: () -> Void = {}

    @AppStorage("raga-sa") private var saOffset = 0
    @AppStorage("raga-tempo") private var tempo = 120
    @AppStorage("raga-label-mode") private var labelMode = "sargam"
    @State private var tempoToken = 0
    /// Cross-studio audio focus registration (P6).
    @EnvironmentObject private var audioFocus: StudioAudioFocus
    @State private var focusToken: UUID?

    private var walk: [ScaleWalk.Note] {
        ScaleWalk.notes(aro: raga.aro, ava: raga.ava)
    }

    var body: some View {
        VStack(spacing: 14) {
            listenCard
            pianoCard
        }
        .onAppear {
            focusToken = audioFocus.register { adapter.stop() }
        }
        .onDisappear {
            adapter.stop()
            if let focusToken { audioFocus.unregister(focusToken) }
        }
        .onChange(of: tempo) { _, newTempo in
            // Web: a tempo change while playing restarts after a
            // 350 ms debounce.
            guard adapter.isPlaying else { return }
            tempoToken += 1
            let token = tempoToken
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                if token == tempoToken, adapter.isPlaying {
                    play(newTempo)
                }
            }
        }
        .onChange(of: saOffset) { _, _ in
            if adapter.isPlaying { play(tempo) }
        }
    }

    private var listenCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                StudioSectionTitle("Listen · harmonium")
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
                    if adapter.isPlaying { adapter.stop() } else { play(tempo) }
                } label: {
                    Text(adapter.isPlaying ? "■ Stop" : "▶ Play")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(StudioPrimaryButtonStyle())
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
                    labels: pianoLabels,
                    highlightRel: player.currentIndex >= 0 && player.currentIndex < walk.count
                        ? walk[player.currentIndex].semitone : nil)
            }
        }
    }

    /// Piano labels by rel, the web's rule: the first spelling met
    /// in arohana-then-avarohana order wins, rel 0…12 only; Western
    /// names in Western mode, the Hindustani mapping when the
    /// notation toggle is Hindustani.
    private var pianoLabels: [Int: String] {
        var map: [Int: String] = [:]
        for token in raga.aro + raga.ava {
            let (base, lift) = ScaleWalk.splitToken(token)
            guard let semi = Swara.semitones[base] else { continue }
            let rel = semi + lift * 12
            guard (0...12).contains(rel), map[rel] == nil else { continue }
            if labelMode == "western" {
                map[rel] = ScaleNotation.western(pitchClass: saOffset + rel)
            } else if hindustaniLabels {
                map[rel] = ScaleNotation.hindustani(base) + (lift > 0 ? "'" : "")
            } else {
                map[rel] = base + (lift > 0 ? "'" : "")
            }
        }
        return map
    }

    private func play(_ atTempo: Int) {
        onPlayStart()
        audioFocus.stopAll(except: focusToken)
        adapter.play(semitones: walk.map { $0.semitone + saOffset },
                     tempo: atTempo)
    }
}
