import Foundation
import AudioKit

/// Varisai playback (web player semantics): all notes scheduled up
/// front from t0 = +0.08 on the harmonium tone engine — sampled
/// playback, not the sustain chain — with a per-token highlight.
/// Looping re-enters at exactly one pattern length, woken 60 ms
/// early like the web's seamless loop timer.
@MainActor
public final class VarisaiPlayer: ObservableObject {
    public enum State: Equatable { case idle, loading, playing }
    @Published public private(set) var state: State = .idle
    @Published public private(set) var currentToken: Int = -1

    private let tone: any ToneEngine
    private var generation = 0
    private var tasks: [Task<Void, Never>] = []
    /// Whether the next seam re-enters (read live at the seam,
    /// like the web's loop toggle — flipping it mid-play takes
    /// effect at the end of the current pass).
    public var loopEnabled = true

    public init(tone: any ToneEngine = HarmoniumToneEngine()) {
        self.tone = tone
    }

    public var isPlaying: Bool { state == .playing }

    /// Start a pattern. tempo 30–90, speed one of 1/2/4/8.
    public func play(pattern: VarisaiPattern, saOffset: Int, tempo: Int,
                     speed: Int, loop: Bool) {
        stop()
        loopEnabled = loop
        generation += 1
        let gen = generation
        state = .loading
        let step = (60.0 / Double(tempo)) / Double(speed)
        let events = VarisaiPlayback.events(notes: pattern.notes, saOffset: saOffset)
        let tokenCount = pattern.notes.count
        Task {
            await tone.prepare()
            guard gen == generation else { return }
            state = .playing
            schedulePass(events: events, tokenCount: tokenCount,
                         step: step, speed: speed, gen: gen, loop: loop,
                         leadIn: 0.08)
        }
    }

    private func schedulePass(events: [VarisaiEvent], tokenCount: Int,
                              step: Double, speed: Int, gen: Int, loop: Bool,
                              leadIn: Double) {
        for (index, event) in events.enumerated() {
            tone.playNote(
                semitone: event.semitone,
                atOffset: leadIn + Double(event.startStep) * step,
                duration: VarisaiPlayback.duration(
                    of: event, isLast: index == events.count - 1,
                    step: step, speed: speed))
        }
        for index in 0..<tokenCount {
            let delay = UInt64((leadIn + Double(index) * step) * 1_000_000_000)
            tasks.append(Task { @MainActor in
                try? await Task.sleep(nanoseconds: delay)
                if gen == generation { currentToken = index }
            })
        }
        let passSeconds = Double(tokenCount) * step
        // Wake 60 ms before the exact pass boundary (the web's
        // seamless-loop timer). At the seam, the live loop toggle
        // decides: re-enter for another pass, or finish.
        let wake = UInt64(max(0, passSeconds - 0.06) * 1_000_000_000)
        tasks.append(Task { @MainActor in
            try? await Task.sleep(nanoseconds: wake)
            if gen == generation {
                tasks.forEach { $0.cancel() }
                tasks = []
                if loopEnabled {
                    // Re-enter with a 0.06 lead-in from the 60 ms-early
                    // wake, so the first note lands on the exact pass
                    // boundary (the web's seamless seam).
                    schedulePass(events: events, tokenCount: tokenCount,
                                 step: step, speed: speed, gen: gen, loop: true,
                                 leadIn: 0.06)
                } else {
                    let endDelay = UInt64((leadIn + 0.16) * 1_000_000_000)
                    tasks.append(Task { @MainActor in
                        try? await Task.sleep(nanoseconds: endDelay)
                        if gen == generation { finish() }
                    })
                }
            }
        })
    }

    public func stop() {
        generation += 1
        tasks.forEach { $0.cancel() }
        tasks = []
        tone.stopAll()
        finish()
    }

    private func finish() {
        state = .idle
        currentToken = -1
    }
}
