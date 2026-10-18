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
    /// Plain value: the phrase strip leaf observes the player, so
    /// this section no longer re-renders per chip pulse.
    let player: PhrasePlayer
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
                        .buttonStyle(StudioSecondaryButtonStyle())
                }
            }
        } else {
            Text("Select a loop to add or play its swaras.")
                .foregroundStyle(.secondary)
        }
    }

    private func phraseBody(loop: LoopRegion, phrase: Phrase) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionPhraseStrip(player: player, loop: loop, phrase: phrase)

            HStack {
                Text("Tempo").foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(phrase.tempo) },
                    set: { controller.setSectionPhraseTempo(
                        Int($0.rounded()), for: loop, context: modelContext) }),
                       in: 30...120, step: 1)
                .tint(Studio.accent)
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
                    .buttonStyle(StudioSecondaryButtonStyle())
            }
        }
    }

    private func metaLine(_ phrase: Phrase) -> String {
        let ragaName = phrase.ragaId.flatMap { controller.ragaLibrary.raga(id: $0)?.name }
            ?? "Chromatic"
        return "\(ragaName) · \(Swara.formatBeats(phrase.totalBeats)) beats"
    }
}

/// The round play button + chip strip for a loop's phrase. This leaf
/// is the section's only observer of the phrase player, so the
/// per-chip highlight pulse re-renders just this strip.
struct SectionPhraseStrip: View {
    @EnvironmentObject private var controller: PlaybackController
    @ObservedObject var player: PhrasePlayer
    let loop: LoopRegion
    let phrase: Phrase

    var body: some View {
        let key = controller.sectionKey(for: loop)
        HStack(spacing: 12) {
            StudioRoundButton(
                systemImage: player.isPlaying(contextKey: key) ? "stop.fill" : "play.fill",
                diameter: 44) {
                controller.toggleSectionPhrase(for: loop)
            }
            LivePhraseChipsView(player: player, chips: phrase.chips, contextKey: key)
        }
    }
}
