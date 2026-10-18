import SwiftUI
import SwiftData
import RagaCore
import PersistenceKit
import SwaraEditor
import DesignSystem

/// The Swaras section on the Loops tab (web #fsSwSection), in the
/// web's order: header row (title + round play / Edit / Add
/// buttons), the selected loop's sub-line, then — for a loop with a
/// phrase — the chip strip, the tempo row and the meta line.
struct SwarasSectionView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var controller: PlaybackController
    /// Plain value: the play button and chip strip observe the
    /// player in leaves, so this section no longer re-renders per
    /// chip pulse.
    let player: PhrasePlayer
    let song: Song
    var onEdit: (LoopRegion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            if let loop = controller.selectedLoop {
                Text("\(loop.name) · A \(fmt(loop.start)) – B \(fmt(loop.end))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let phrase = controller.phrase(for: loop), !phrase.chips.isEmpty {
                    phraseBody(loop: loop, phrase: phrase)
                } else {
                    Text("No swaras for this loop yet. Tap ＋ Add swaras to compose the phrase you hear in this loop.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Select a loop to add its swaras.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            StudioSectionTitle("Swaras")
            Spacer()
            if let loop = controller.selectedLoop {
                if let phrase = controller.phrase(for: loop), !phrase.chips.isEmpty {
                    SectionPlayButton(player: player, loop: loop)
                    Button("✎ Edit") { onEdit(loop) }
                        .buttonStyle(StudioSecondaryButtonStyle())
                } else {
                    Button("＋ Add swaras") { onEdit(loop) }
                        .buttonStyle(StudioSecondaryButtonStyle())
                }
            }
        }
    }

    private func phraseBody(loop: LoopRegion, phrase: Phrase) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LivePhraseChipsView(player: player, chips: phrase.chips,
                                contextKey: controller.sectionKey(for: loop))
            HStack {
                Text("Tempo").foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(phrase.tempo) },
                    set: { controller.setSectionPhraseTempo(
                        Int($0.rounded()), for: loop, context: modelContext) }),
                       in: 30...120, step: 1)
                .tint(Studio.accent)
                Text("\(phrase.tempo) bpm")
                    .font(.callout).monospacedDigit()
            }
            Text(metaLine(phrase))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func metaLine(_ phrase: Phrase) -> String {
        let ragaName = phrase.ragaId.flatMap { controller.ragaLibrary.raga(id: $0)?.name }
            ?? "Chromatic"
        return "\(ragaName) · \(Swara.formatBeats(phrase.totalBeats)) beats"
    }

    private func fmt(_ t: Double) -> String { LibraryView.formatDuration(t) }
}

/// The header's round play button for the selected loop's phrase —
/// a leaf observer of the phrase player (web's roundplay in the
/// section header).
struct SectionPlayButton: View {
    @EnvironmentObject private var controller: PlaybackController
    @ObservedObject var player: PhrasePlayer
    let loop: LoopRegion

    var body: some View {
        StudioRoundButton(
            systemImage: player.isPlaying(contextKey: controller.sectionKey(for: loop))
                ? "stop.fill" : "play.fill",
            diameter: 32) {
            controller.toggleSectionPhrase(for: loop)
        }
    }
}
