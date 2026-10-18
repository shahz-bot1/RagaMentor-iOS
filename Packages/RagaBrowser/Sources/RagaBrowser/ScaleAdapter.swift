import Foundation
import AudioKit

/// The Raga Listen adapter (SequencePlayer design §8): builds a
/// plain Timeline from a scale's semitones and drives the shared
/// SequencePlayer with the no-loop policy. Studio behaviour stays
/// here — the web duration rule (step × (1 + min(1.5, 0.075 /
/// step))), the 0.10 lead-in, and the end landing 0.30 s after the
/// last note's step. The core knows none of it.
///
/// Replaces ScalePlayer (P-B). The adapter owns the studio's
/// SequencePlayer and its tone engine until P-E moves the single
/// engine construction site to the app shell.
@MainActor
public final class ScaleAdapter: ObservableObject {
    /// The shared core; the Listen section observes this.
    public let player: SequencePlayer
    private let tone: any ToneEngine
    private let beeper = TestBeep()

    public static let contextKey = "scale"

    public init() {
        let tone = HarmoniumToneEngine()
        self.tone = tone
        self.player = SequencePlayer(tone: tone)
    }

    /// Playing for host purposes (includes the prepare window).
    public var isPlaying: Bool { player.isPlaying(contextKey: Self.contextKey) }
    public var currentIndex: Int { player.currentIndex }
    /// Readiness for a status line (design §6.5).
    public var samplesReady: Bool { tone.samplesReady }

    public func play(semitones: [Int], tempo: Int) {
        player.play(timeline: Self.timeline(semitones: semitones, tempo: tempo),
                    policy: NoLoopPolicy(), contextKey: Self.contextKey)
    }

    public func stop() { player.stop() }

    /// The web's 880 Hz test beep, on its own engine (TestBeep) so
    /// it never disturbs the harmonium pool.
    public func beep() { beeper.beep() }

    // MARK: - Timeline (the adapter's contract; unit-tested)

    public static func timeline(semitones: [Int], tempo: Int) -> Timeline {
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
