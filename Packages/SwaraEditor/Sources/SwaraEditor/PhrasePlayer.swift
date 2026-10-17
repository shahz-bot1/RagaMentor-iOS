import Foundation
import RagaCore
import AudioKit

/// Phrase playback, shared by the LoopLab section and the swara editor
/// (and Compose in P2). Scheduling follows the web player: all note
/// events are scheduled up front from the RagaCore expansion; chip
/// highlights fire per chip start; at the end (+0.4 s) the phrase
/// restarts when loop is on and the host context is still valid.
/// Playback instances are told apart by a context key ("section:<id>",
/// "editor:<id>") so hosts can highlight only their own playback.
@MainActor
public final class PhrasePlayer: ObservableObject {
    @Published public private(set) var activeContextKey: String?
    @Published public private(set) var currentChipIndex: Int = -1

    public let tone: any ToneEngine
    private var generation = 0
    private var jobs: [Task<Void, Never>] = []

    public init(tone: any ToneEngine) {
        self.tone = tone
    }

    public var isPlaying: Bool { activeContextKey != nil }
    public func isPlaying(contextKey: String) -> Bool { activeContextKey == contextKey }

    public func play(phrase: Phrase, contextKey: String,
                     contextValid: @escaping () -> Bool = { true }) {
        stop()
        guard !phrase.chips.isEmpty else { return }
        generation += 1
        let gen = generation
        activeContextKey = contextKey
        Task { [weak self] in
            guard let self else { return }
            await tone.prepare()
            guard generation == gen, activeContextKey == contextKey else { return }
            schedule(phrase: phrase, contextKey: contextKey,
                     generation: gen, contextValid: contextValid)
        }
    }

    private func schedule(phrase: Phrase, contextKey: String,
                          generation gen: Int, contextValid: @escaping () -> Bool) {
        let beat = 60.0 / Double(phrase.tempo)
        for event in PhraseExpansion.events(for: phrase) {
            let slice = event.durationBeats * beat
            tone.playNote(
                semitone: Swara.semitone(st: event.st, oct: event.oct, saOffset: phrase.saOffset),
                atOffset: 0.1 + event.startBeat * beat,
                duration: slice + min(0.28, slice * 0.7)) // web soundDur rule
        }
        var t = 0.0
        for (index, chip) in phrase.chips.enumerated() {
            let start = t
            jobs.append(Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((0.1 + start * beat) * 1_000_000_000))
                guard let self, !Task.isCancelled, generation == gen else { return }
                currentChipIndex = index
            })
            t += chip.beats
        }
        let totalSeconds = t * beat
        jobs.append(Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((0.1 + totalSeconds + 0.4) * 1_000_000_000))
            guard let self, !Task.isCancelled, generation == gen else { return }
            if phrase.loop && contextValid() {
                play(phrase: phrase, contextKey: contextKey, contextValid: contextValid)
            } else {
                finish()
            }
        })
    }

    private func finish() {
        jobs.forEach { $0.cancel() }
        jobs = []
        activeContextKey = nil
        currentChipIndex = -1
    }

    public func stop() {
        generation += 1
        tone.stopAll()
        finish()
    }

    public func toggle(phrase: Phrase, contextKey: String,
                       contextValid: @escaping () -> Bool = { true }) {
        if activeContextKey == contextKey { stop() }
        else { play(phrase: phrase, contextKey: contextKey, contextValid: contextValid) }
    }
}
