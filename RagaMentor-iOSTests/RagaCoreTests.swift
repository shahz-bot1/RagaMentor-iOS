import XCTest
import RagaCore

// RagaCore tests (PARITY-PLAN §6: the v0.6.0 suite, split per module in P0).
final class RagaCoreTests: XCTestCase {

    func testSHA256KnownVector() {
        // FIPS 180-4 example: SHA-256("abc")
        XCTAssertEqual(AudioHash.sha256Hex(of: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testTimeMathRoundTrip() {
        XCTAssertEqual(TimeMath.frames(forSeconds: 1.5, sampleRate: 48000), 72000)
        XCTAssertEqual(TimeMath.seconds(forFrames: 72000, sampleRate: 48000), 1.5)
        XCTAssertEqual(TimeMath.frames(forSeconds: 2, sampleRate: 0), 0)
        XCTAssertEqual(TimeMath.clamp(5, min: 0, max: 3), 3)
        XCTAssertEqual(TimeMath.clamp(-1, min: 0, max: 3), 0)
    }

    func testLoopNormalizeClampsAndSwaps() {
        let swapped = LoopRules.normalize(start: 8, end: 3, duration: 10)
        XCTAssertEqual(swapped?.start, 3)
        XCTAssertEqual(swapped?.end, 8)

        let clamped = LoopRules.normalize(start: -2, end: 99, duration: 10)
        XCTAssertEqual(clamped?.start, 0)
        XCTAssertEqual(clamped?.end, 10)
    }

    func testLoopNormalizeMinLength() {
        let extended = LoopRules.normalize(start: 4, end: 4.1, duration: 10)
        XCTAssertNotNil(extended)
        XCTAssertEqual(extended!.end - extended!.start, LoopRules.minLength, accuracy: 1e-9)

        // At the very end of the song the start pulls back instead.
        let atEdge = LoopRules.normalize(start: 9.9, end: 10, duration: 10)
        XCTAssertNotNil(atEdge)
        XCTAssertEqual(atEdge!.end, 10)
        XCTAssertEqual(atEdge!.end - atEdge!.start, LoopRules.minLength, accuracy: 1e-9)

        // A song shorter than the minimum loop cannot hold a loop.
        XCTAssertNil(LoopRules.normalize(start: 0, end: 0.2, duration: 0.2))
    }

    func testCanSplit() {
        XCTAssertTrue(LoopRules.canSplit(loopStart: 1, loopEnd: 5, at: 3))
        XCTAssertFalse(LoopRules.canSplit(loopStart: 1, loopEnd: 5, at: 1.2))
        XCTAssertFalse(LoopRules.canSplit(loopStart: 1, loopEnd: 5, at: 4.9))
        XCTAssertTrue(LoopRules.canSplit(loopStart: 1, loopEnd: 5, at: 1.3))
    }

    func testSplitSecondName() {
        XCTAssertEqual(LoopRules.splitSecondName(originalName: "Pallavi", existingNames: []), "Pallavi 2")
        XCTAssertEqual(LoopRules.splitSecondName(originalName: "Loop 1", existingNames: []), "Loop 2")
        XCTAssertEqual(LoopRules.splitSecondName(originalName: "Take 9", existingNames: []), "Take 10")
        XCTAssertEqual(LoopRules.splitSecondName(originalName: "Pallavi", existingNames: ["Pallavi 2"]), "Pallavi 3")
        XCTAssertEqual(LoopRules.splitSecondName(originalName: "Loop 1", existingNames: ["Loop 2", "Loop 3"]), "Loop 4")
    }

    func testGroupDerivedRange() {
        let l1 = UUID(), l2 = UUID(), l3 = UUID()
        let g1 = UUID(), g2 = UUID()
        let spans: [UUID: LoopSpan] = [
            l1: LoopSpan(id: l1, start: 10, end: 20),
            l2: LoopSpan(id: l2, start: 5, end: 8),
            l3: LoopSpan(id: l3, start: 30, end: 40),
        ]
        // g1 (top) holds l1 and g2; g2 (sub) holds l2, l3.
        let children: [UUID: [UUID]] = [g1: [l1, g2], g2: [l2, l3]]

        let sub = GroupLogic.derivedRange(groupID: g2, children: children, spans: spans)
        XCTAssertEqual(sub?.start, 5)
        XCTAssertEqual(sub?.end, 40)

        let top = GroupLogic.derivedRange(groupID: g1, children: children, spans: spans)
        XCTAssertEqual(top?.start, 5)
        XCTAssertEqual(top?.end, 40)

        let empty = GroupLogic.derivedRange(groupID: UUID(), children: children, spans: spans)
        XCTAssertNil(empty)
    }

    func testPeaksBucketize() {
        let samples: [Float] = [0.1, -0.5, 0.2, 0.9, -0.3, 0.05, 0.4, -0.8]
        let peaks = Peaks.bucketize(samples: samples, buckets: 4)
        XCTAssertEqual(peaks.count, 4)
        XCTAssertEqual(peaks[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(peaks[1], 0.9, accuracy: 1e-6)
        XCTAssertEqual(peaks[2], 0.3, accuracy: 1e-6)
        XCTAssertEqual(peaks[3], 0.8, accuracy: 1e-6)

        XCTAssertEqual(Peaks.bucketize(samples: [], buckets: 3), [0, 0, 0])
        XCTAssertEqual(Peaks.bucketize(samples: samples, buckets: 0), [])
    }

    func testLoopPositionWraps() {
        // Segment 1.0s..2.0s at 48k: 48000 frames starting at 48000.
        let sr = 48000.0
        XCTAssertEqual(LoopMath.loopPosition(segmentStartFrame: 48000, segmentFrameCount: 48000,
                                             playedFrames: 0, sampleRate: sr), 1.0)
        XCTAssertEqual(LoopMath.loopPosition(segmentStartFrame: 48000, segmentFrameCount: 48000,
                                             playedFrames: 24000, sampleRate: sr), 1.5)
        // Exactly at the boundary wraps back to the segment start.
        XCTAssertEqual(LoopMath.loopPosition(segmentStartFrame: 48000, segmentFrameCount: 48000,
                                             playedFrames: 48000, sampleRate: sr), 1.0)
        // Two and a half passes in.
        XCTAssertEqual(LoopMath.loopPosition(segmentStartFrame: 48000, segmentFrameCount: 48000,
                                             playedFrames: 120000, sampleRate: sr), 1.5)
    }

    func testShouldReschedule() {
        XCTAssertTrue(LoopMath.shouldReschedule(loopEnabled: true, eventGeneration: 3, currentGeneration: 3))
        XCTAssertFalse(LoopMath.shouldReschedule(loopEnabled: false, eventGeneration: 3, currentGeneration: 3))
        XCTAssertFalse(LoopMath.shouldReschedule(loopEnabled: true, eventGeneration: 2, currentGeneration: 3))
    }

    func testLoopPositionFirstPassOffset() {
        // Segment 10s..20s at 10 Hz sample rate for easy math:
        // start frame 100, count 100, entry offset 30 (entered at 13s).
        let sr = 10.0
        // First pass: played 0 -> 13s; played 69 -> 19.9s.
        XCTAssertEqual(LoopMath.loopPosition(segmentStartFrame: 100, segmentFrameCount: 100,
                                             firstPassOffsetFrames: 30, playedFrames: 0, sampleRate: sr), 13.0)
        XCTAssertEqual(LoopMath.loopPosition(segmentStartFrame: 100, segmentFrameCount: 100,
                                             firstPassOffsetFrames: 30, playedFrames: 69, sampleRate: sr), 19.9, accuracy: 1e-9)
        // played 70 = end of first pass -> wraps to segment start (10s).
        XCTAssertEqual(LoopMath.loopPosition(segmentStartFrame: 100, segmentFrameCount: 100,
                                             firstPassOffsetFrames: 30, playedFrames: 70, sampleRate: sr), 10.0)
        // played 100 -> 30 frames into the second pass (13s).
        XCTAssertEqual(LoopMath.loopPosition(segmentStartFrame: 100, segmentFrameCount: 100,
                                             firstPassOffsetFrames: 30, playedFrames: 100, sampleRate: sr), 13.0)
        // Zero offset matches the plain wrap.
        XCTAssertEqual(LoopMath.loopPosition(segmentStartFrame: 100, segmentFrameCount: 100,
                                             firstPassOffsetFrames: 0, playedFrames: 250, sampleRate: sr),
                       LoopMath.loopPosition(segmentStartFrame: 100, segmentFrameCount: 100,
                                             playedFrames: 250, sampleRate: sr))
    }

    func testGroupOpsDescendantsAndEmpty() {
        let l1 = UUID(), l2 = UUID(), l3 = UUID()
        let g1 = UUID(), g2 = UUID(), g3 = UUID()
        let groups = [
            GroupData(id: g1, memberIDs: [l1, g2]),
            GroupData(id: g2, memberIDs: [l2]),
            GroupData(id: g3, memberIDs: []),
        ]
        let loops: Set<UUID> = [l1, l2, l3]
        XCTAssertEqual(Set(GroupOps.descendantLoopIDs(of: g1, groups: groups, loopIDs: loops)), [l1, l2])
        XCTAssertEqual(GroupOps.descendantLoopIDs(of: g3, groups: groups, loopIDs: loops), [])
        XCTAssertEqual(GroupOps.emptyGroupIDs(groups: groups, loopIDs: loops), [g3])
        // Cascading: if g2 loses its loop, both g2 and g1 become empty.
        let groups2 = [
            GroupData(id: g1, memberIDs: [g2]),
            GroupData(id: g2, memberIDs: []),
        ]
        XCTAssertEqual(GroupOps.emptyGroupIDs(groups: groups2, loopIDs: loops), [g1, g2])
    }

    func testGroupOpsDeletePromotesChildren() {
        let l1 = UUID(), l2 = UUID(), l3 = UUID()
        let g1 = UUID(), g2 = UUID()
        let groups = [
            GroupData(id: g1, memberIDs: [l1, g2]),
            GroupData(id: g2, memberIDs: [l2, l3]),
        ]
        let after = GroupOps.deletingGroup(g2, from: groups)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(Set(after[0].memberIDs), [l1, l2, l3])
        // Deleting a top-level group leaves children ungrouped.
        let afterTop = GroupOps.deletingGroup(g1, from: groups)
        XCTAssertEqual(afterTop.count, 1)
        XCTAssertEqual(afterTop[0].id, g2)
    }

    func testGroupOpsSettingMembersSteals() {
        let l1 = UUID(), l2 = UUID()
        let g1 = UUID(), g2 = UUID()
        let groups = [
            GroupData(id: g1, memberIDs: [l1, l2]),
            GroupData(id: g2, memberIDs: []),
        ]
        let after = GroupOps.settingMembers(of: g2, to: [l2], in: groups)
        XCTAssertEqual(after.first { $0.id == g1 }?.memberIDs, [l1])
        XCTAssertEqual(after.first { $0.id == g2 }?.memberIDs, [l2])
    }

    func testGroupOpsSortedMembers() {
        let l1 = UUID(), l2 = UUID(), g1 = UUID()
        let spans: [UUID: LoopSpan] = [
            l1: LoopSpan(id: l1, start: 20, end: 30),
            l2: LoopSpan(id: l2, start: 5, end: 8),
        ]
        let groups = [GroupData(id: g1, memberIDs: [l2])]
        // Group's derived start is 5; tie broken deterministically.
        let sorted = GroupOps.sortedMemberIDs([l1, g1, l2], groups: groups, spans: spans)
        XCTAssertEqual(sorted.first, l2)
        XCTAssertEqual(sorted.last, l1)
        XCTAssertEqual(sorted.count, 3)
    }

    func testBackupRoundTrip() throws {
        let l1 = UUID(), l2 = UUID(), g1 = UUID(), g2 = UUID()
        let file = LoopsBackup.make(
            songTitle: "Song",
            duration: 100,
            loops: [
                .init(id: l1, name: "Intro", note: "Sa = C#", start: 0, end: 10),
                .init(id: l2, name: "Chorus", note: "", start: 20, end: 35),
            ],
            groups: [
                .init(id: g1, name: "All", colorHex: "#111111", memberIDs: [l1, g2]),
                .init(id: g2, name: "Sub", colorHex: "#222222", memberIDs: [l2]),
            ])
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(LoopsBackupFile.self, from: data)
        XCTAssertEqual(decoded, file)

        let plan = try LoopsBackup.planImport(file: decoded, duration: 100)
        XCTAssertEqual(plan.loops.map(\.name), ["Intro", "Chorus"])
        XCTAssertEqual(plan.loops[0].note, "Sa = C#")
        XCTAssertEqual(plan.groups.count, 2)
        let all = try XCTUnwrap(plan.groups.first { $0.name == "All" })
        let sub = try XCTUnwrap(plan.groups.first { $0.name == "Sub" })
        // Membership resolved to the FRESH ids, structure intact.
        XCTAssertTrue(all.memberIDs.contains(sub.id))
        XCTAssertEqual(sub.memberIDs, [plan.loops[1].id])
        XCTAssertNotEqual(sub.id, g2)
    }

    func testBackupImportGuards() throws {
        // Version gate.
        var bad = LoopsBackupFile(songTitle: "X", duration: 10, loops: [], groups: [])
        bad.version = 99
        XCTAssertThrowsError(try LoopsBackup.planImport(file: bad, duration: 10))

        // A holder group nested inside another group breaks the cap and
        // is dropped as a member; ranges clamp to a shorter target song.
        let file = LoopsBackupFile(
            songTitle: "X", duration: 100,
            loops: [.init(serial: 1, name: "L", note: "", start: 0, end: 90)],
            groups: [
                .init(serial: 2, name: "Outer", colorHex: "#000000", memberSerials: [3]),
                .init(serial: 3, name: "Holder", colorHex: "#000000", memberSerials: [4]),
                .init(serial: 4, name: "Inner", colorHex: "#000000", memberSerials: [1]),
            ])
        let plan = try LoopsBackup.planImport(file: file, duration: 50)
        XCTAssertEqual(plan.loops.first?.end, 50) // clamped from 90
        // Outer held only Holder; Holder was dropped as a member (cap),
        // leaving Outer with no descendant loops — so it vanishes (§6).
        // Holder survives at top level, still holding Inner and the loop.
        XCTAssertEqual(Set(plan.groups.map(\.name)), ["Holder", "Inner"])
        let holder = try XCTUnwrap(plan.groups.first { $0.name == "Holder" })
        let inner = try XCTUnwrap(plan.groups.first { $0.name == "Inner" })
        XCTAssertEqual(holder.memberIDs, [inner.id])
        XCTAssertEqual(inner.memberIDs, [plan.loops[0].id])
    }
}
