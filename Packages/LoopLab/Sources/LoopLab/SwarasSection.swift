import SwiftUI
import SwiftData
import RagaCore
import PersistenceKit
import SwaraEditor
import DesignSystem

/// The Swaras section on the Loops tab (web fsSwSection): for the
/// selected loop — a prompt when no loop is selected, an Add button
/// when the loop has no phrase, or the read-only phrase strip with the
/// round play button, Edit, the tempo slider and the meta line.
struct SwarasSectionView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var controller: PlaybackController
    @ObservedObject var player: PhrasePlayer
    let song: Song
    var onEdit: (LoopRegion) -> Void

    var body: some View {
        if let loop = controller.selectedLoop {
            if let phrase = controller.phrase(for: loop), !phrase.chips.isEmpty {
                phraseBody(loop: loop, phrase: phrase)
            } else {
                HStack {
                    Text("No swaras for this loop yet.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("＋ Add swaras") { onEdit(loop) }
                }
            }
        } else {
            Text("Select a loop to add or play its swaras.")
                .foregroundStyle(.secondary)
        }
    }

    private func phraseBody(loop: LoopRegion, phrase: Phrase) -> some View {
        let playing = player.isPlaying(contextKey: controller.sectionKey(for: loop))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    controller.toggleSectionPhrase(for: loop)
                } label: {
                    Text(playing ? "■" : "▶")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.bordered)
                .clipShape(Circle())
                .tint(playing ? .red : DesignTokens.accent)

                PhraseChipsView(
                    chips: phrase.chips,
                    currentIndex: playing ? player.currentChipIndex : -1)
            }

            HStack {
                Text("Tempo").foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(phrase.tempo) },
                    set: { controller.setSectionPhraseTempo(
                        Int($0.rounded()), for: loop, context: modelContext) }),
                       in: 30...120, step: 1)
                Text("\(phrase.tempo) bpm")
                    .font(.callout.monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
            }

            HStack {
                Text(metaLine(phrase))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("✎ Edit") { onEdit(loop) }
            }
        }
    }

    private func metaLine(_ phrase: Phrase) -> String {
        let ragaName = phrase.ragaId.flatMap { controller.ragaLibrary.raga(id: $0)?.name }
            ?? "Chromatic"
        return "\(ragaName) · \(Swara.formatBeats(phrase.totalBeats)) beats"
    }
}
