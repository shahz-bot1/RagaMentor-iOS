import XCTest
import RagaCore
import AudioKit

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
}
