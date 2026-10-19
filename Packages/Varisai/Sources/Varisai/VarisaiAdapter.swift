import Foundation
import RagaCore
import AudioKit

/// The Varisai adapter (SequencePlayer design §8): builds a
/// plain Timeline from a pattern via VarisaiPlayback and drives
/// the shared SequencePlayer with the seamless policy. Studio
/// behaviour stays here — the step math ((60 ÷ tempo) ÷ speed),
/// the dheergam slot extension and legato overlap durations,
/// the 0.08 lead-in, and the live loop toggle the policy reads
/// at the seam. The core knows none of it.
///
/// Replaces VarisaiPlayer (P-D). The adapter holds the loop
/// toggle; the SeamlessPolicy reads it at the seam, so flipping
/// the toggle mid-pass takes effect at the end of the current
/// pass, exactly as the old player's seam timer did.
@MainActor
public final class VarisaiAdapter {
    /// The shared core; observing leaves subscribe to this.
    public let player: SequencePlayer

    public static let contextKey = "varisai"

    /// The live loop toggle, read by the policy at the seam.
    public var loopEnabled = true

    public init(player: SequencePlayer) {
        self.player = player
    }

    public convenience init(tone: any ToneEngine) {
        self.init(player: SequencePlayer(tone: tone))
    }

    // MARK: - State (the old VarisaiPlayer surface, forwarded)

    public var state: SequenceState { player.state }
    /// Scoped state (v1.5.18): the core is shared, so the raw
    /// player state belongs to whichever studio is playing.
    /// These reads answer for VARISAI only — during a phrase
    /// pass the lesson used to show Stop and highlight tokens
    /// by chip index. (Commands were already guarded; the
    /// state reads were not.)
    public var isPlaying: Bool { player.isPlaying(contextKey: Self.contextKey) }
    public var currentToken: Int {
        player.contextKey == Self.contextKey ? player.currentIndex : -1
    }

    // MARK: - Commands

    /// Start a pattern. tempo 30–90, speed one of 1/2/4/8.
    public func play(pattern: VarisaiPattern, saOffset: Int, tempo: Int,
                     speed: Int, loop: Bool) {
        loopEnabled = loop
        player.play(
            timeline: Self.timeline(pattern: pattern, saOffset: saOffset,
                                    tempo: tempo, speed: speed),
            policy: SeamlessPolicy(isLoopOn: { [weak self] in
                self?.loopEnabled ?? false
            }),
            contextKey: Self.contextKey)
    }

    /// Stop only a Varisai pass: on the shared core (P-E) a stop
    /// aimed at Varisai must not kill another studio's pass.
    public func stop() {
        if player.contextKey == Self.contextKey { player.stop() }
    }

    // MARK: - Timeline (the adapter's contract; unit-tested)

    /// Pattern → Timeline. One step per token: holds extend the
    /// preceding event's slots during expansion (VarisaiPlayback),
    /// and every token — holds included — is one highlight step,
    /// so the highlight grid is the plain token grid.
    public nonisolated static func timeline(pattern: VarisaiPattern,
                                            saOffset: Int, tempo: Int,
                                            speed: Int) -> Timeline {
        let step = (60.0 / Double(tempo)) / Double(speed)
        let events = VarisaiPlayback.events(notes: pattern.notes,
                                            saOffset: saOffset)
        var notes: [TimelineNote] = []
        for (index, event) in events.enumerated() {
            notes.append(TimelineNote(
                semitone: event.semitone,
                start: Double(event.startStep) * step,
                duration: VarisaiPlayback.duration(
                    of: event, isLast: index == events.count - 1,
                    step: step, speed: speed),
                highlight: event.startStep))
        }
        return Timeline(
            notes: notes,
            passDuration: Double(pattern.notes.count) * step,
            highlightCount: pattern.notes.count,
            highlightStarts: (0..<pattern.notes.count).map { Double($0) * step },
            leadIn: 0.08)
    }
}
