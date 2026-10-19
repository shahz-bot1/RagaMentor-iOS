import Foundation
import RagaCore
import AudioKit

/// The phrase adapter (SequencePlayer design §8): builds a plain
/// Timeline from a Phrase via PhraseExpansion and drives the
/// shared SequencePlayer with the restart-after-gap policy.
/// Studio behaviour stays here — the soundDur rule (slice +
/// min(0.28, slice × 0.7)), the 0.10 lead-in, the web's +0.40 s
/// loop breath, and the host context keys (`section:` / `editor:`
/// / list hosts) with their validity checks. The core knows none
/// of it.
///
/// Replaces PhrasePlayer (P-C). One adapter wraps the app's ONE
/// sequence player for phrases: LoopLab's section and editor and
/// every Compose host share it, told apart by context key exactly
/// as before.
@MainActor
public final class PhraseAdapter {
    /// The shared core; observing leaves subscribe to this.
    public let player: SequencePlayer

    public init(player: SequencePlayer) {
        self.player = player
    }

    public convenience init(tone: any ToneEngine) {
        self.init(player: SequencePlayer(tone: tone))
    }

    // MARK: - State (the old PhrasePlayer surface, forwarded)

    public var activeContextKey: String? { player.contextKey }
    // (No unscoped chip-index surface: the phrase views read
    // the player with their own context key — PhraseChipsView.)
    public func isPlaying(contextKey key: String) -> Bool {
        player.isPlaying(contextKey: key)
    }

    // MARK: - Commands

    public func play(phrase: Phrase, contextKey key: String,
                     contextValid: @escaping () -> Bool = { true }) {
        player.play(
            timeline: Self.timeline(for: phrase),
            policy: RestartAfterGapPolicy(gap: 0.4, isLoopOn: { phrase.loop }),
            contextKey: key, contextValid: contextValid)
    }

    public func toggle(phrase: Phrase, contextKey key: String,
                       contextValid: @escaping () -> Bool = { true }) {
        if isPlaying(contextKey: key) { stop() }
        else { play(phrase: phrase, contextKey: key, contextValid: contextValid) }
    }

    /// Stop a phrase pass. On the shared core (P-E) a stop aimed
    /// at phrases must not kill another studio's pass, so the
    /// other adapters' well-known context keys are left alone
    /// (ScaleAdapter's "scale", VarisaiAdapter's "varisai").
    public func stop() {
        if let key = player.contextKey, key == "scale" || key == "varisai" {
            return
        }
        player.stop()
    }

    // MARK: - Timeline (the adapter's contract; unit-tested)

    /// Phrase → Timeline. Expansion events already carry absolute
    /// semitones and beat positions; chip starts are the
    /// cumulative chip beats. Holds and gaps produce no notes —
    /// they shape durations and starts during expansion, before
    /// the core ever sees the phrase (design §8.3).
    public nonisolated static func timeline(for phrase: Phrase) -> Timeline {
        let beat = 60.0 / Double(phrase.tempo)
        let notes = PhraseExpansion.events(for: phrase).map { event in
            let slice = event.durationBeats * beat
            return TimelineNote(
                semitone: Swara.semitone(st: event.st, oct: event.oct,
                                          saOffset: phrase.saOffset),
                start: event.startBeat * beat,
                duration: slice + min(0.28, slice * 0.7),
                highlight: event.chipIndex)
        }
        var starts: [Double] = []
        var cursor = 0.0
        for chip in phrase.chips {
            starts.append(cursor * beat)
            cursor += chip.beats
        }
        return Timeline(
            notes: notes,
            passDuration: phrase.totalBeats * beat,
            highlightCount: phrase.chips.count,
            highlightStarts: starts,
            leadIn: 0.1)
    }
}
