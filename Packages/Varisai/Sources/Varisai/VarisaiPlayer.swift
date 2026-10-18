import Foundation
import AudioKit

/// Varisai playback (web player semantics): all notes scheduled up
/// front from t0 = +0.08 on the harmonium tone engine — sampled
/// playback, not the sustain chain. The highlight is DERIVED from
/// the pass timeline by one ticker (20 ms): index = elapsed ÷ step
/// from a single origin, published only when it changes. The old
/// per-token sleeping tasks drifted against the audio and could
/// coalesce at high speed, which read as late and skipped
/// highlights. Looping re-enters at exactly one pattern length,
/// woken 60 ms early like the web's seamless loop timer.
@MainActor
public final class VarisaiPlayer: ObservableObject {
    public enum State: Equatable { case idle, loading, playing }
    @Published public private(set) var state: State = .idle
    @Published public private(set) var currentToken: Int = -1

    private let tone: any ToneEngine
    private var generation = 0
    private var tasks: [Task<Void, Never>] = []
    private var tickerTask: Task<Void, Never>?
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
            let origin = Date().addingTimeInterval(0.08)
            schedulePass(events: events, tokenCount: tokenCount,
                         step: step, speed: speed, gen: gen, loop: loop,
                         leadIn: 0.08)
            startTicker(origin: origin, step: step,
                        tokenCount: tokenCount, gen: gen)
        }
    }

    /// The highlight ticker: derives the current token from the
    /// elapsed time since the pass origin. With looping, the
    /// position wraps at exactly one pattern length (the audio
    /// seam lands the next pass on the same boundary).
    private func startTicker(origin: Date, step: Double,
                             tokenCount: Int, gen: Int) {
        tickerTask?.cancel()
        let passSeconds = Double(tokenCount) * step
        tickerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
                guard gen == generation, state == .playing else { return }
                let elapsed = Date().timeIntervalSince(origin)
                if elapsed < 0 {
                    if currentToken != -1 { currentToken = -1 }
                    continue
                }
                if elapsed >= passSeconds, !loopEnabled {
                    finish()
                    return
                }
                let pos = loopEnabled
                    ? elapsed.truncatingRemainder(dividingBy: passSeconds)
                    : elapsed
                let index = min(tokenCount - 1, Int(pos / step))
                if index != currentToken { currentToken = index }
            }
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
        let passSeconds = Double(tokenCount) * step
        // Wake 60 ms before the exact pass boundary (the web's
        // seamless-loop timer). At the seam, the live loop toggle
        // decides: re-enter for another pass, or finish. The sleep
        // is measured from NOW, but the pass's first note sounds
        // after this pass's lead-in — so the lead-in counts toward
        // the boundary: sleep = pass + leadIn − 0.06. (Before this
        // fix the lead-in was not counted, and every pass from the
        // second onward started ~80 ms ahead of the boundary —
        // and of the highlight ticker's grid.)
        let wake = UInt64(max(0, passSeconds + leadIn - 0.06) * 1_000_000_000)
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
                }
            }
        })
    }

    public func stop() {
        generation += 1
        tasks.forEach { $0.cancel() }
        tasks = []
        tickerTask?.cancel()
        tickerTask = nil
        tone.stopAll()
        finish()
    }

    private func finish() {
        state = .idle
        currentToken = -1
    }
}
