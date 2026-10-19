import Foundation
import AudioKit

/// The Raga Listen adapter (SequencePlayer design §8): builds a
/// plain Timeline from a scale's semitones and drives the shared
/// SequencePlayer with the no-loop policy. Studio behaviour stays
/// here — the web duration rule (step × (1 + min(1.5, 0.075 /
/// step))), the 0.10 lead-in, and the end landing 0.30 s after the
/// last note's step. The core knows none of it.
///
/// Replaces ScalePlayer (P-B). The adapter wraps the app's one
/// shared SequencePlayer (P-E) — the single tone engine lives
/// in the app shell; the adapter constructs nothing.
@MainActor
public final class ScaleAdapter: ObservableObject {
    /// The shared core; the Listen section observes this.
    public let player: SequencePlayer

    public static let contextKey = "scale"

    public init(player: SequencePlayer) {
        self.player = player
    }

    /// Playing for host purposes (includes the prepare window).
    public var isPlaying: Bool { player.isPlaying(contextKey: Self.contextKey) }
    /// Scoped (v1.5.18): another studio's pass must not drive
    /// the scale rows' highlight.
    public var currentIndex: Int {
        player.contextKey == Self.contextKey ? player.currentIndex : -1
    }

    public func play(semitones: [Int], tempo: Int) {
        player.play(timeline: Self.timeline(semitones: semitones, tempo: tempo),
                    policy: NoLoopPolicy(), contextKey: Self.contextKey)
    }

    /// Stop only a scale pass: on the shared core (P-E) a stop
    /// aimed at scales must not kill another studio's pass.
    public func stop() {
        if player.contextKey == Self.contextKey { player.stop() }
    }

    // MARK: - Timeline (the adapter's contract; unit-tested)

    /// Pure value construction — nonisolated so tests and callers
    /// never need the main actor for it.
    public nonisolated static func timeline(semitones: [Int], tempo: Int) -> Timeline {
        let step = 60.0 / Double(tempo)
        let duration = step * (1 + min(1.5, 0.075 / step))
        let notes = semitones.enumerated().map { index, semitone in
            TimelineNote(semitone: semitone,
                         start: Double(index) * step,
                         duration: duration,
                         highlight: index)
        }
        return Timeline(
            notes: notes,
            // The pass ends 0.30 s after the last note's step,
            // exactly as ScalePlayer's finish task did.
            passDuration: Double(semitones.count) * step + 0.3,
            highlightCount: semitones.count,
            highlightStarts: notes.map(\.start),
            leadIn: 0.1)
    }
}
