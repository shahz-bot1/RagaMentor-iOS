import XCTest
import AVFoundation
import RagaCore
import AudioKit
import RagaBrowser
import SwaraEditor
import Varisai

// SequencePlayer tests (design P-A) — the pure timeline math, the
// two P-A loop policies, and the core's scheduling/state behaviour
// against a fake tone engine. Timing expectations reuse the design
// document's numbers (§8.3 worked example; §11.2 test strategy).
final class SequencePlayerTests: XCTestCase {

    private final class FakeTone: ToneEngine {
        var samplesReady = true
        var played: [(semi: Int, offset: Double, dur: Double)] = []
        var stopCount = 0
        func prepare() async {}
        func playNote(semitone: Int, atOffset offset: Double, duration: Double) {
            played.append((semitone, offset, duration))
        }
        func stopAll() { stopCount += 1 }
    }

    // MARK: - TimelineIndex

    func testIndexBeforeFirstStartIsMinusOne() {
        XCTAssertEqual(TimelineIndex.index(at: 0.05, starts: [0.1, 0.6], count: 2), -1)
        XCTAssertEqual(TimelineIndex.index(at: 0.0, starts: [], count: 0), -1)
    }

    func testIndexAtExactStart() {
        XCTAssertEqual(TimelineIndex.index(at: 0.1, starts: [0.1, 0.6], count: 2), 0)
        XCTAssertEqual(TimelineIndex.index(at: 0.6, starts: [0.1, 0.6], count: 2), 1)
    }

    func testIndexWithUnevenStarts() {
        // Phrase chips of 0.5, 0.5 and 2 beats at 1 s per beat.
        let starts = [0.0, 0.5, 1.0]
        XCTAssertEqual(TimelineIndex.index(at: 0.49, starts: starts, count: 3), 0)
        XCTAssertEqual(TimelineIndex.index(at: 0.75, starts: starts, count: 3), 1)
        XCTAssertEqual(TimelineIndex.index(at: 2.99, starts: starts, count: 3), 2)
        XCTAssertEqual(TimelineIndex.index(at: 99.0, starts: starts, count: 3), 2)
    }

    func testPassWrapArithmetic() {
        let p0 = TimelineIndex.pass(elapsed: 0, duration: 2.0)
        XCTAssertEqual(p0.pass, 0); XCTAssertEqual(p0.offset, 0, accuracy: 1e-9)
        let p1 = TimelineIndex.pass(elapsed: 2.0, duration: 2.0)
        XCTAssertEqual(p1.pass, 1); XCTAssertEqual(p1.offset, 0, accuracy: 1e-9)
        let p2 = TimelineIndex.pass(elapsed: 5.5, duration: 2.0)
        XCTAssertEqual(p2.pass, 2); XCTAssertEqual(p2.offset, 1.5, accuracy: 1e-9)
        // Long elapsed: pure division, no accumulated drift.
        let p3 = TimelineIndex.pass(elapsed: 3_600.3, duration: 0.3)
        XCTAssertEqual(p3.pass, 12_001)
        XCTAssertEqual(p3.offset, 0.0, accuracy: 1e-6)
    }

    // MARK: - Policies

    func testNoLoopAlwaysStops() {
        XCTAssertEqual(NoLoopPolicy().boundary(), .stop)
        XCTAssertEqual(NoLoopPolicy().wakeEarly, 0)
    }

    func testRestartAfterGapHonoursFlag() {
        var on = true
        let policy = RestartAfterGapPolicy(gap: 0.4, isLoopOn: { on })
        XCTAssertEqual(policy.boundary(), .again(leadIn: 0.4))
        on = false
        XCTAssertEqual(policy.boundary(), .stop)
    }

    func testSeamlessReadsToggleAtSeam() {
        var on = true
        let policy = SeamlessPolicy(isLoopOn: { on })
        XCTAssertEqual(policy.wakeEarly, 0.06)
        XCTAssertEqual(policy.boundary(), .again(leadIn: 0.06))
        on = false
        XCTAssertEqual(policy.boundary(), .stop)
    }

    // MARK: - Core behaviour

    /// The design §8.3 worked example, as a timeline.
    private func exampleTimeline() -> Timeline {
        Timeline(
            notes: [
                TimelineNote(semitone: 0, start: 0.0, duration: 1.28, highlight: 0),
                TimelineNote(semitone: 2, start: 1.0, duration: 0.78, highlight: 1),
                TimelineNote(semitone: 4, start: 1.5, duration: 0.78, highlight: 1),
            ],
            passDuration: 2.0, highlightCount: 2,
            highlightStarts: [0.0, 1.0], leadIn: 0.1)
    }

    @MainActor
    private func poll(until condition: @MainActor () -> Bool, timeout: Double = 3.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func testPlaySchedulesNotesAtLeadInPlusStart() async {
        let tone = FakeTone()
        let player = await MainActor.run { SequencePlayer(tone: tone) }
        await MainActor.run {
            player.play(timeline: exampleTimeline(), policy: NoLoopPolicy(),
                        contextKey: "test")
        }
        let scheduled = await poll(until: { tone.played.count == 3 })
        XCTAssertTrue(scheduled)
        XCTAssertEqual(tone.played.map(\.semi), [0, 2, 4])
        XCTAssertEqual(tone.played[0].offset, 0.1, accuracy: 0.03)
        XCTAssertEqual(tone.played[1].offset, 1.1, accuracy: 0.03)
        XCTAssertEqual(tone.played[2].offset, 1.6, accuracy: 0.03)
        let state = await MainActor.run { player.state }
        XCTAssertEqual(state, .playing)
        let key = await MainActor.run { player.contextKey }
        XCTAssertEqual(key, "test")
        await MainActor.run { player.stop() }
    }

    func testNoLoopFinishesAndSettlesToIdle() async {
        let tone = FakeTone()
        let player = await MainActor.run { SequencePlayer(tone: tone) }
        await MainActor.run {
            player.play(timeline: exampleTimeline(), policy: NoLoopPolicy(),
                        contextKey: "test")
        }
        // Pass is 2.0 s + 0.1 lead-in; the settle adds ~0.06.
        let settled = await poll(until: {
            player.state == .idle && player.currentIndex == -1 && player.contextKey == nil
        }, timeout: 4.0)
        XCTAssertTrue(settled)
    }

    func testGapLoopReentersWhileFlagHolds() async {
        let tone = FakeTone()
        let player = await MainActor.run { SequencePlayer(tone: tone) }
        var on = true
        let policy = RestartAfterGapPolicy(gap: 0.05, isLoopOn: { on })
        await MainActor.run {
            player.play(timeline: exampleTimeline(), policy: policy,
                        contextKey: "test")
        }
        // First pass: 3 notes. Re-entry after 2.0 + 0.05 gap + 0.1
        // lead-in schedules 3 more.
        let reentered = await poll(until: { tone.played.count >= 6 }, timeout: 4.0)
        XCTAssertTrue(reentered)
        on = false
        let settled = await poll(until: { player.state == .idle }, timeout: 5.0)
        XCTAssertTrue(settled)
    }

    func testContextValidGateBlocksReentry() async {
        let tone = FakeTone()
        let player = await MainActor.run { SequencePlayer(tone: tone) }
        let policy = RestartAfterGapPolicy(gap: 0.05, isLoopOn: { true })
        await MainActor.run {
            player.play(timeline: exampleTimeline(), policy: policy,
                        contextKey: "test", contextValid: { false })
        }
        let settled = await poll(until: { player.state == .idle }, timeout: 4.0)
        XCTAssertTrue(settled)
        XCTAssertEqual(tone.played.count, 3) // never re-entered
    }

    // MARK: - ScaleAdapter timeline (P-B)

    func testScaleTimelineShape() {
        // Mohanam's walk shape: aro + ava with the upper-Sa wrap.
        let semis = ScaleWalk.semitones(aro: ["S", "R2", "G3", "P", "D2", "S'"],
                                        ava: ["S'", "D2", "P", "G3", "R2", "S"],
                                        saOffset: 0)
        let timeline = ScaleAdapter.timeline(semitones: semis, tempo: 120)
        XCTAssertEqual(timeline.leadIn, 0.1)
        XCTAssertEqual(timeline.highlightCount, semis.count)
        XCTAssertEqual(timeline.notes.count, semis.count)
        // step = 0.5 at 120 bpm; duration = 0.5 × (1 + min(1.5, 0.15)).
        XCTAssertEqual(timeline.notes[0].start, 0)
        XCTAssertEqual(timeline.notes[1].start, 0.5, accuracy: 1e-9)
        XCTAssertEqual(timeline.notes[0].duration, 0.575, accuracy: 1e-9)
        let highlights = timeline.notes.map { $0.highlight }
        XCTAssertEqual(highlights, Array(0..<semis.count))
        // The pass ends 0.30 s after the last note's step.
        XCTAssertEqual(timeline.passDuration,
                       Double(semis.count) * 0.5 + 0.3, accuracy: 1e-9)
        let starts = timeline.notes.map { $0.start }
        XCTAssertEqual(timeline.highlightStarts, starts)
    }

    func testScaleTimelineAtTempo240() {
        let timeline = ScaleAdapter.timeline(semitones: [0, 2, 4], tempo: 240)
        // step = 0.25; duration = 0.25 × (1 + min(1.5, 0.3)) = 0.325.
        XCTAssertEqual(timeline.notes[1].start, 0.25, accuracy: 1e-9)
        XCTAssertEqual(timeline.notes[0].duration, 0.325, accuracy: 1e-9)
        XCTAssertEqual(timeline.passDuration, 3 * 0.25 + 0.3, accuracy: 1e-9)
    }

    func testScaleTimelineAtTempo60() {
        let timeline = ScaleAdapter.timeline(semitones: [0, 2], tempo: 60)
        // step = 1; duration = the web rule, 1.075 (the settled
        // state after the blend calibration ended at 0%).
        XCTAssertEqual(timeline.notes[0].duration, 1.075, accuracy: 1e-9)
    }

    // MARK: - PhraseAdapter timeline (P-C)

    func testPhraseTimelineWithStackHoldAndGap() {
        // Tempo 60 → one beat = 1 s. Chip 0: single S. Chip 1:
        // a two-note stack. Chip 2: a hold (extends the stack's
        // final unit). Chip 3: a gap (silent). Chip 4: P.
        let phrase = Phrase(ragaId: nil, saOffset: 0, tempo: 60, loop: false, chips: [
            .note([StackEntry(st: "S", oct: 0)], beats: 1),
            .note([StackEntry(st: "R2", oct: 0), StackEntry(st: "G3", oct: 0)], beats: 1),
            .hold(beats: 1),
            .gap(beats: 1),
            .note([StackEntry(st: "P", oct: 0)], beats: 1),
        ])
        let timeline = PhraseAdapter.timeline(for: phrase)
        XCTAssertEqual(timeline.leadIn, 0.1)
        XCTAssertEqual(timeline.passDuration, 5.0, accuracy: 1e-9)
        XCTAssertEqual(timeline.highlightCount, 5)
        XCTAssertEqual(timeline.highlightStarts, [0, 1, 2, 3, 4])
        XCTAssertEqual(timeline.notes.count, 4)
        let semis = timeline.notes.map { $0.semitone }
        XCTAssertEqual(semis, [0, 2, 4, 7])
        let starts = timeline.notes.map { $0.start }
        XCTAssertEqual(starts, [0, 1, 1.5, 4])
        let highlights = timeline.notes.map { $0.highlight }
        XCTAssertEqual(highlights, [0, 1, 1, 4])
        // soundDur = slice + min(0.28, slice × 0.7): S slice 1 →
        // 1.28; R2 slice 0.5 → 0.78; G3 slice 0.5 + 1 hold = 1.5
        // → 1.78; P slice 1 → 1.28.
        let durations = timeline.notes.map { $0.duration }
        XCTAssertEqual(durations.count, 4)
        XCTAssertEqual(durations[0], 1.28, accuracy: 1e-9)
        XCTAssertEqual(durations[1], 0.78, accuracy: 1e-9)
        XCTAssertEqual(durations[2], 1.78, accuracy: 1e-9)
        XCTAssertEqual(durations[3], 1.28, accuracy: 1e-9)
    }

    func testSeamlessReentryLandsOnBoundary() async {
        let tone = FakeTone()
        let player = await MainActor.run { SequencePlayer(tone: tone) }
        let timeline = Timeline(
            notes: [TimelineNote(semitone: 0, start: 0, duration: 0.1,
                                 highlight: 0)],
            passDuration: 0.4, highlightCount: 1,
            highlightStarts: [0], leadIn: 0.1)
        await MainActor.run {
            player.play(timeline: timeline,
                        policy: SeamlessPolicy(isLoopOn: { true }),
                        contextKey: "test")
        }
        let reentered = await poll(until: { tone.played.count >= 2 },
                                   timeout: 3.0)
        XCTAssertTrue(reentered)
        // The core wakes 60 ms before the 0.4 s boundary; the
        // policy's 0.06 lead-in is measured from the wake, so the
        // next pass's first note is scheduled 0.06 ahead — it
        // lands ON the boundary, not 0.06 past it (which would
        // read 0.12 here).
        XCTAssertEqual(tone.played[1].offset, 0.06, accuracy: 0.04)
        await MainActor.run { player.stop() }
    }

    // MARK: - VarisaiAdapter timeline (P-D)

    func testVarisaiTimelineWithDheergamAtSpeed8() {
        // S held by a dheergam comma, then R2, G3. Tempo 60,
        // speed 8 → step = 0.125.
        let pattern = VarisaiPattern(
            title: "T", sub: "", laya: nil, tala: nil,
            notes: ["S", ",", "R2", "G3"],
            dlines: [[["S", ",", "R2", "G3"]]])
        let timeline = VarisaiAdapter.timeline(
            pattern: pattern, saOffset: 0, tempo: 60, speed: 8)
        XCTAssertEqual(timeline.leadIn, 0.08)
        XCTAssertEqual(timeline.passDuration, 0.5, accuracy: 1e-9)
        XCTAssertEqual(timeline.highlightCount, 4)
        XCTAssertEqual(timeline.highlightStarts, [0, 0.125, 0.25, 0.375])
        XCTAssertEqual(timeline.notes.count, 3)
        let semis = timeline.notes.map { $0.semitone }
        XCTAssertEqual(semis, [0, 2, 4])
        let starts = timeline.notes.map { $0.start }
        XCTAssertEqual(starts, [0, 0.25, 0.375])
        let highlights = timeline.notes.map { $0.highlight }
        XCTAssertEqual(highlights, [0, 2, 3])
        // Overlap at 8x = max(2.0, 0.25 ÷ step) = 2.0. S spans
        // two slots → 0.125 × 2 × 2.0 = 0.5; R2 one slot → 0.25;
        // the last event keeps max(base × 0.96, step × factor)
        // = max(0.24, 0.25) = 0.25.
        let durations = timeline.notes.map { $0.duration }
        XCTAssertEqual(durations.count, 3)
        XCTAssertEqual(durations[0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(durations[1], 0.25, accuracy: 1e-9)
        XCTAssertEqual(durations[2], 0.25, accuracy: 1e-9)
    }

    func testStopCancelsPlayback() async {
        let tone = FakeTone()
        let player = await MainActor.run { SequencePlayer(tone: tone) }
        await MainActor.run {
            player.play(timeline: exampleTimeline(), policy: NoLoopPolicy(),
                        contextKey: "test")
        }
        _ = await poll(until: { tone.played.count == 3 })
        await MainActor.run { player.stop() }
        let state = await MainActor.run { player.state }
        XCTAssertEqual(state, .idle)
        XCTAssertGreaterThanOrEqual(tone.stopCount, 1)
    }

    func testInterruptionStopsPlaybackAndStaysStopped() async {
        // Shahzin's ruling (v1.5.17): when another app takes the
        // audio session, sequence playback stops and stays
        // stopped — it does not resume mid-pass afterwards.
        let tone = FakeTone()
        let player = await MainActor.run { SequencePlayer(tone: tone) }
        await MainActor.run {
            player.play(timeline: exampleTimeline(), policy: NoLoopPolicy(),
                        contextKey: "test")
        }
        _ = await poll(until: { tone.played.count >= 1 })
        let stopsBefore = tone.stopCount
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey:
                        AVAudioSession.InterruptionType.began.rawValue])
        let stopped = await poll(until: { player.state == .idle })
        XCTAssertTrue(stopped)
        XCTAssertGreaterThan(tone.stopCount, stopsBefore)
        // …and an interruption END does not restart it.
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey:
                        AVAudioSession.InterruptionType.ended.rawValue])
        try? await Task.sleep(nanoseconds: 300_000_000)
        let state = await MainActor.run { player.state }
        XCTAssertEqual(state, .idle)
    }
}
