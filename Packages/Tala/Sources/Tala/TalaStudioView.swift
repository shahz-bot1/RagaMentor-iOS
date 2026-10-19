import SwiftUI
import RagaCore
import AudioKit
import DesignSystem

/// Tala Studio (web tala/index.html): the wheel, the tala and
/// jati selectors, tempo with tap, the nadai subdivision segment,
/// and the fixed Start/Stop bar.
public struct TalaStudioView: View {
    @StateObject private var clock = TalaClock()
    private let onPlayStart: () -> Void
    /// Cross-studio audio focus registration (P6).
    @EnvironmentObject private var audioFocus: StudioAudioFocus
    @State private var focusToken: UUID?

    public init(onPlayStart: @escaping () -> Void) {
        self.onPlayStart = onPlayStart
    }

    private var isChapu: Bool { TalaSpec.isChapu(clock.settings.talaId) }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    StudioCard {
                        TalaWheelView(talaId: clock.settings.talaId,
                                      jatiId: clock.settings.jatiId,
                                      currentBeat: clock.currentBeat)
                            .frame(maxWidth: 300)
                            .frame(maxWidth: .infinity)
                    }
                    talaCard
                    jatiCard
                    tempoCard
                    Text("Samam glows gold · gaps mark anga boundaries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .background(Studio.bg.ignoresSafeArea())
            .navigationTitle("Tala Studio")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                focusToken = clock.attachFocus(audioFocus)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Button {
                        if clock.isPlaying {
                            clock.stop()
                        } else {
                            audioFocus.stopAll(except: focusToken)
                            onPlayStart()
                            clock.start()
                        }
                    } label: {
                        Text(clock.isPlaying ? "■ Stop" : "▶ Start")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Studio.accent,
                                        in: RoundedRectangle(cornerRadius: 16))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .background(Studio.bg)
            }
        }
    }

    private var talaCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                StudioSectionTitle("Tala · suladi sapta")
                // Pills size to their text and wrap as whole
                // units (FlowStack) — the adaptive grid and the
                // shared-width rows squeezed them until the
                // words hyphenated (v1.5.15).
                FlowStack(items: TalaSpec.talas.map(TalaChipItem.init)) { item in
                    StudioChip(item.def.name,
                               selected: clock.settings.talaId == item.def.id) {
                        clock.setTala(item.def.id)
                    }
                }
                FlowStack(items: TalaSpec.chapu.map(TalaChipItem.init)) { item in
                    StudioChip("\(item.def.name) · \(item.def.count)",
                               selected: clock.settings.talaId == item.def.id) {
                        clock.setTala(item.def.id)
                    }
                }
            }
        }
    }

    private var jatiCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                StudioSectionTitle("Jati · laghu length — n/a for chapu")
                FlowStack(items: TalaSpec.jatis.map(JatiChipItem.init)) { item in
                    StudioChip("\(item.def.name) \(item.def.value)",
                               selected: clock.settings.jatiId == item.def.id) {
                        clock.setJati(item.def.id)
                    }
                }
                .opacity(isChapu ? 0.35 : 1)
                .disabled(isChapu)
            }
        }
    }

    private var tempoCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 12) {
                StudioSectionTitle("Tempo")
                HStack(spacing: 12) {
                    Slider(value: Binding(
                        get: { Double(clock.settings.bpm) },
                        set: { clock.setBPM(Int($0.rounded())) }),
                        in: 30...120, step: 1)
                        .tint(Studio.accent)
                    Text("\(clock.settings.bpm) bpm")
                        .font(.callout).monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                    Button("Tap") { clock.tap() }
                        .buttonStyle(StudioSecondaryButtonStyle())
                }
                StudioSectionTitle("Subdivision")
                StudioSegmented(
                    items: [("1", "1st"), ("2", "2nd"), ("3", "Tisra"), ("4", "Chatusra")],
                    selection: Binding(
                        get: { String(clock.settings.nadai) },
                        set: { clock.setNadai(Int($0) ?? 4) }))
            }
        }
    }
}

/// FlowStack item wrappers (the TalaSpec defs are not
/// Identifiable).
private struct TalaChipItem: Identifiable {
    let def: TalaSpec.TalaDef
    var id: String { def.id }
}

private struct JatiChipItem: Identifiable {
    let def: TalaSpec.JatiDef
    var id: String { def.id }
}
