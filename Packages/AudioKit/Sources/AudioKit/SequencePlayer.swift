import Foundation
import AVFoundation
import RagaCore

/// The shared sequence playback core (design: SequencePlayer
/// Detailed Design §5–§7). One player for every swara sequence —
/// phrases, scales, Varisai patterns — over one ToneEngine.
///
/// Rule 1 (design §10.1): the core speaks in plain values only —
/// semitones, seconds, indices. It never learns what a chip, a
/// raga or a dheergam is; adapters in the feature packages build
/// the timeline and apply their studio's duration rule.
/// Rule 2: loop behaviour is an injected LoopPolicy, never an
/// enum inside the core.

// MARK: - Timeline values

/// One scheduled note: absolute semitone, start (seconds from the
/// pass origin), sounding duration, and the highlight index the
/// view lights while it sounds. Several notes may share one
/// highlight (a phrase chip's stack); a highlight may own no note
/// at all (a hold chip still advances the strip).
public struct TimelineNote: Equatable, Sendable {
    public var semitone: Int
    public var start: Double
    public var duration: Double
    public var highlight: Int
    public init(semitone: Int, start: Double, duration: Double, highlight: Int) {
        self.semitone = semitone
        self.start = start
        self.duration = duration
        self.highlight = highlight
    }
}

/// A finished pass, ready to schedule. `highlightStarts` carries
/// the start offset of every highlight inside the pass, so uneven
/// phrase chips highlight correctly without the core knowing what
/// a beat is (design §8.1).
public struct Timeline: Equatable, Sendable {
    public var notes: [TimelineNote]
    public var passDuration: Double
    public var highlightCount: Int
    public var highlightStarts: [Double]
    public var leadIn: Double
    public init(notes: [TimelineNote], passDuration: Double,
                highlightCount: Int, highlightStarts: [Double], leadIn: Double) {
        self.notes = notes
        self.passDuration = passDuration
        self.highlightCount = highlightCount
        self.highlightStarts = highlightStarts
        self.leadIn = leadIn
    }
}

// MARK: - Loop policies (injected, design §7)

public enum BoundaryDecision: Equatable {
    case stop
    /// Re-enter for another pass. `leadIn` is measured from the
    /// policy's wake point (the boundary minus its `wakeEarly`);
    /// for a policy that wakes at the boundary the core adds the
    /// timeline's own lead-in on top (see armBoundary).
    case again(leadIn: Double)
}

/// Consulted by the core at a pass boundary. `wakeEarly` is how
/// long before the boundary the core asks (0.06 for the seamless
/// policy, which must schedule the next pass before the boundary;
/// 0 for policies that decide at or after it).
public protocol LoopPolicy: AnyObject {
    var wakeEarly: Double { get }
    func boundary() -> BoundaryDecision
}

public extension LoopPolicy {
    var wakeEarly: Double { 0 }
}

/// Scales: one pass, then finish (design §7.1).
public final class NoLoopPolicy: LoopPolicy {
    public init() {}
    public func boundary() -> BoundaryDecision { .stop }
}

/// Phrases: restart after the web's +0.40 s breath, while the
/// loop flag holds. The host-context check is the core's (design
/// §6.4 carries contextValid on play); the re-entry lead-in is the
/// gap plus the timeline's own lead-in, exactly as the old
/// PhrasePlayer composed them (end task at +0.4, replay at +0.1).
public final class RestartAfterGapPolicy: LoopPolicy {
    public var gap: Double
    public var isLoopOn: () -> Bool
    public init(gap: Double = 0.4, isLoopOn: @escaping () -> Bool) {
        self.gap = gap
        self.isLoopOn = isLoopOn
    }
    public func boundary() -> BoundaryDecision {
        // Returns the gap only; the core adds the timeline's own
        // lead-in on top for policies that wake at the boundary
        // (see armBoundary).
        isLoopOn() ? .again(leadIn: gap) : .stop
    }
}

/// Varisai: the seamless loop (design §7.1). The core wakes
/// 60 ms before the boundary and asks; the toggle is read live
/// at the seam, so flipping it mid-pass takes effect at the end
/// of the current pass (the web's loop semantics). The returned
/// lead-in is measured from the wake point: 0.06 from a wake
/// 60 ms early lands the next pass's first note exactly on the
/// boundary — the v1.3.2 seam arithmetic as core code.
public final class SeamlessPolicy: LoopPolicy {
    public var isLoopOn: () -> Bool
    public init(isLoopOn: @escaping () -> Bool) {
        self.isLoopOn = isLoopOn
    }
    public var wakeEarly: Double { 0.06 }
    public func boundary() -> BoundaryDecision {
        isLoopOn() ? .again(leadIn: 0.06) : .stop
    }
}

// MARK: - State contract (design §6.2)

public enum SequenceState: Equatable {
    case idle
    case loading
    case playing
    case finished
}

// MARK: - The core

@MainActor
public final class SequencePlayer: ObservableObject {
    @Published public private(set) var state: SequenceState = .idle
    @Published public private(set) var currentIndex: Int = -1
    @Published public private(set) var contextKey: String?
    @Published public private(set) var elapsed: Double = 0
    @Published public private(set) var passDuration: Double = 0

    public var isPlaying: Bool { state == .playing }

    private let tone: any ToneEngine
    private var generation = 0
    private var tickerTask: Task<Void, Never>?
    private var boundaryTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?

    // The active pass, in origin-relative seconds.
    private var timeline: Timeline?
    private var policy: (any LoopPolicy)?
    private var contextValid: () -> Bool = { true }
    private var origin = Date()
    private var passOffset: Double = 0

    private var interruptionObserver: NSObjectProtocol?

    public init(tone: any ToneEngine) {
        self.tone = tone
        // Interruption policy (v1.5.17, Shahzin's ruling): when
        // another app takes the audio session, sequence playback
        // STOPS and stays stopped — a lesson does not resume
        // mid-pass. (The LoopLab song holds the opposite policy —
        // pause and resume — owned by PlaybackController.) The
        // tone engine heals itself, so the next manual Play
        // sounds normally.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: nil) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began
                else { return }
                Task { @MainActor in
                    guard let self else { return }
                    if self.state == .playing || self.state == .loading { self.stop() }
                }
            }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    /// "Playing" for host purposes includes preparing the samples —
    /// the old PhrasePlayer set its key before prepare() too, so a
    /// toggle during loading stops rather than double-starts.
    public func isPlaying(contextKey key: String) -> Bool {
        (state == .playing || state == .loading) && contextKey == key
    }

    public func play(timeline: Timeline, policy: any LoopPolicy,
                     contextKey key: String,
                     contextValid: @escaping () -> Bool = { true }) {
        stop()
        guard timeline.passDuration > 0 else { return }
        generation += 1
        let gen = generation
        self.timeline = timeline
        self.policy = policy
        self.contextValid = contextValid
        contextKey = key
        passDuration = timeline.passDuration
        state = .loading
        Task { [weak self] in
            guard let self else { return }
            await tone.prepare()
            guard generation == gen, state == .loading else { return }
            begin(timeline: timeline, gen: gen)
        }
    }

    public func toggle(timeline: Timeline, policy: any LoopPolicy,
                       contextKey key: String,
                       contextValid: @escaping () -> Bool = { true }) {
        if isPlaying(contextKey: key) { stop() }
        else { play(timeline: timeline, policy: policy,
                    contextKey: key, contextValid: contextValid) }
    }

    public func stop() {
        generation += 1
        tickerTask?.cancel(); tickerTask = nil
        boundaryTask?.cancel(); boundaryTask = nil
        settleTask?.cancel(); settleTask = nil
        tone.stopAll()
        timeline = nil
        policy = nil
        state = .idle
        currentIndex = -1
        contextKey = nil
        elapsed = 0
        passDuration = 0
    }

    // MARK: - Pass lifecycle

    private func begin(timeline: Timeline, gen: Int) {
        origin = Date().addingTimeInterval(timeline.leadIn)
        passOffset = 0
        state = .playing
        scheduleNotes(timeline: timeline, passStart: 0)
        startTicker(gen: gen)
        armBoundary(gen: gen)
    }

    /// Schedule a pass's notes. `passStart` is the pass's first
    /// note time in origin-relative seconds; note offsets are
    /// converted to "seconds from now" for the engine.
    private func scheduleNotes(timeline: Timeline, passStart: Double) {
        let now = -origin.timeIntervalSinceNow // seconds since origin (negative during lead-in)
        for note in timeline.notes {
            let at = passStart + note.start - now
            tone.playNote(semitone: note.semitone,
                          atOffset: max(0, at), duration: note.duration)
        }
    }

    private func startTicker(gen: Int) {
        tickerTask?.cancel()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
                guard let self, generation == gen, state == .playing,
                      let timeline else { return }
                let total = -origin.timeIntervalSinceNow
                elapsed = total
                let local = total - passOffset
                let index = local < 0
                    ? -1
                    : TimelineIndex.index(at: local,
                                          starts: timeline.highlightStarts,
                                          count: timeline.highlightCount)
                if index != currentIndex { currentIndex = index }
            }
        }
    }

    /// Ask the policy at its own wake point (design §7.1): at the
    /// boundary minus the policy's wake-early.
    private func armBoundary(gen: Int) {
        boundaryTask?.cancel()
        guard let timeline, let policy else { return }
        let wakeAt = passOffset + timeline.passDuration - policy.wakeEarly
        let delay = wakeAt - (-origin.timeIntervalSinceNow)
        boundaryTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, generation == gen, state == .playing,
                  let timeline = self.timeline,
                  let policy = self.policy else { return }
            switch policy.boundary() {
            case .stop:
                finish()
            case .again(let policyLeadIn):
                guard contextValid() else { finish(); return }
                // A policy's lead-in is measured from its own
                // wake point. Gap-style policies wake AT the
                // boundary and return the gap alone; the pass's
                // own lead-in rides on top (the old phrase player
                // composed +0.4 gap and +0.1 lead-in the same
                // way). An early-wake policy returns the full
                // wake-to-first-note distance, so its offset from
                // the boundary is leadIn − wakeEarly: the seamless
                // policy's 0.06 from a wake 60 ms early lands the
                // next pass's first note exactly on the boundary.
                let leadIn = policy.wakeEarly > 0
                    ? policyLeadIn - policy.wakeEarly
                    : policyLeadIn + timeline.leadIn
                let nextStart = passOffset + timeline.passDuration + leadIn
                scheduleNotes(timeline: timeline, passStart: nextStart)
                passOffset = nextStart
                armBoundary(gen: gen)
            }
        }
    }

    /// Emit .finished (design D4), clear the highlight, then settle
    /// to idle on the next cycle so no view needs its own timer.
    private func finish() {
        tickerTask?.cancel(); tickerTask = nil
        boundaryTask?.cancel(); boundaryTask = nil
        state = .finished
        currentIndex = -1
        let gen = generation
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard let self, generation == gen, state == .finished else { return }
            state = .idle
            contextKey = nil
            elapsed = 0
            passDuration = 0
            timeline = nil
            policy = nil
        }
    }
}
