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

    // MARK: - P1: swara model, sanitizer, expansion

    func testSemitoneMapAsCodedOnWeb() {
        XCTAssertEqual(Swara.semitones["S"], 0)
        XCTAssertEqual(Swara.semitones["R3"], 2) // as coded in all three web sources
        XCTAssertEqual(Swara.semitones["G2"], 3)
        XCTAssertEqual(Swara.semitones["N3"], 11)
        XCTAssertEqual(Swara.chromatic.count, 16)
        XCTAssertTrue(Swara.beatOK(0.25) && Swara.beatOK(8) && Swara.beatOK(2.75))
        XCTAssertFalse(Swara.beatOK(0.3) || Swara.beatOK(0) || Swara.beatOK(8.25))
    }

    private func sanitize(_ json: String) -> Phrase? {
        PhraseSanitizer.sanitize(data: Data(json.utf8),
                                 isKnownRaga: { RagaCatalog.curatedRaga(id: $0) != nil })
    }

    func testPhraseSanitizerRejectsMalformed() {
        // Unknown sthana anywhere rejects the whole phrase.
        XCTAssertNil(sanitize(#"{"chips":[{"k":"note","stack":[{"st":"X9","oct":0}],"beats":1}]}"#))
        // Empty stack rejects.
        XCTAssertNil(sanitize(#"{"chips":[{"k":"note","stack":[],"beats":1}]}"#))
        // A non-object chip rejects.
        XCTAssertNil(sanitize(#"{"chips":[42]}"#))
        // No chips array at all.
        XCTAssertNil(sanitize(#"{"tempo":90}"#))
    }

    func testPhraseSanitizerCoercions() {
        let p = sanitize(#"{"ragaId":"nope","saOffset":14,"tempo":500,"loop":1,"chips":[{"k":"note","stack":[{"st":"R2","oct":5}],"beats":0.3},{"k":"hold","beats":2.75}]}"#)
        let phrase = try! XCTUnwrap(p)
        XCTAssertNil(phrase.ragaId)               // unknown raga → Chromatic
        XCTAssertEqual(phrase.saOffset, 0)        // out of range → 0
        XCTAssertEqual(phrase.tempo, 120)         // clamped
        XCTAssertTrue(phrase.loop)
        XCTAssertEqual(phrase.chips[0].beats, 1)  // invalid beats → 1
        XCTAssertEqual(phrase.chips[0].stack[0].oct, 0) // oct out of set → 0
        XCTAssertEqual(phrase.chips[1].beats, 2.75)     // quarter steps kept
        // The {composition:} envelope is accepted.
        let env = sanitize(#"{"composition":{"ragaId":"kalyani","tempo":90,"chips":[]}}"#)
        XCTAssertEqual(env?.ragaId, "kalyani")
        XCTAssertEqual(env?.tempo, 90)
        // Missing tempo defaults to 60.
        XCTAssertEqual(sanitize(#"{"chips":[]}"#)?.tempo, 60)
    }

    func testExpansionStackSubdividesEqually() {
        // Web: a stack's own duration divides over ALL its entries.
        let phrase = Phrase(ragaId: nil, saOffset: 0, tempo: 60, loop: false, chips: [
            .note([StackEntry(st: "S", oct: 0), StackEntry(st: "R2", oct: 0)], beats: 2),
        ])
        let events = PhraseExpansion.events(for: phrase)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].durationBeats, 1)
        XCTAssertEqual(events[1].startBeat, 1)
        XCTAssertEqual(events[1].durationBeats, 1)
    }

    func testExpansionInStackHoldAddsShareToPreviousUnit() {
        // Stack [S, hold, R2] over 3 beats: sub = 1; S takes 2 shares.
        let phrase = Phrase(ragaId: nil, saOffset: 0, tempo: 60, loop: false, chips: [
            .note([StackEntry(st: "S", oct: 0), .hold, StackEntry(st: "R2", oct: 0)], beats: 3),
        ])
        let events = PhraseExpansion.events(for: phrase)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].durationBeats, 2)
        XCTAssertEqual(events[1].durationBeats, 1)
        XCTAssertEqual(events[1].startBeat, 2)
    }

    func testExpansionOuterHoldLandsEntirelyOnFinalUnit() {
        // Note (2 beats, stack of 2) + hold chip (1 beat): units 1 and 2.
        let phrase = Phrase(ragaId: nil, saOffset: 0, tempo: 60, loop: false, chips: [
            .note([StackEntry(st: "S", oct: 0), StackEntry(st: "G3", oct: 0)], beats: 2),
            .hold(beats: 1),
        ])
        let events = PhraseExpansion.events(for: phrase)
        XCTAssertEqual(events.map(\.durationBeats), [1, 2])
    }

    func testExpansionGapClosesAndLeadingHoldIsSilent() {
        let phrase = Phrase(ragaId: nil, saOffset: 0, tempo: 60, loop: false, chips: [
            .hold(beats: 1),                                 // no pending: silent advance
            .note([StackEntry(st: "S", oct: 0)], beats: 1),  // starts at beat 1
            .gap(beats: 1),                                  // closes S, silent beat
            .note([StackEntry(st: "P", oct: 0)], beats: 1),  // starts at beat 3
            .note([.hold], beats: 2),                        // all-hold stack extends P
        ])
        let events = PhraseExpansion.events(for: phrase)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].startBeat, 1)
        XCTAssertEqual(events[0].durationBeats, 1)
        XCTAssertEqual(events[1].startBeat, 3)
        XCTAssertEqual(events[1].durationBeats, 3)
    }

    func testChipLabelsCarryOctaveDots() {
        XCTAssertEqual(SwaraLabel.noteLabel(st: "S", oct: 1), "S\u{0307}")
        XCTAssertEqual(SwaraLabel.noteLabel(st: "R2", oct: -1), "R\u{0323}₂")
        XCTAssertEqual(SwaraLabel.noteLabel(st: "G3", oct: 0), "G₃")
        XCTAssertEqual(SwaraLabel.chipLabel(.hold(beats: 1)), ",")
        XCTAssertEqual(SwaraLabel.chipLabel(.gap(beats: 1)), "–")
        XCTAssertEqual(
            SwaraLabel.chipLabel(.note([StackEntry(st: "S", oct: 0), .hold], beats: 1)), "S,")
        XCTAssertEqual(Swara.formatBeats(2.5), "2½")
        XCTAssertEqual(Swara.formatBeats(0.25), "¼")
    }

    // MARK: - P1: raga catalog + resolution

    func testCatalogCounts() {
        XCTAssertEqual(RagaCatalog.all.count, 87)
        XCTAssertEqual(RagaCatalog.all.filter { $0.melakartaNumber != nil }.count, 72)
        XCTAssertEqual(RagaCatalog.all.filter { $0.isHindustani }.count, 11)
        XCTAssertEqual(RagaCatalog.curated.count, 10)
        XCTAssertEqual(RagaCatalog.catalogRaga(id: "mel029")?.name, "Dheerasankarabharanam")
    }

    func testResolveCuratedByScaleSignature() {
        // RagaBrowser's mel029 has the Shankarabharanam scale under a
        // different name — the pick resolves to the table id (web rule).
        let mel29 = try! XCTUnwrap(RagaCatalog.catalogRaga(id: "mel029"))
        let hit = RagaCatalog.resolveCurated(name: mel29.name, aro: mel29.aro, ava: mel29.ava)
        XCTAssertEqual(hit?.id, "shankarabharanam")
    }

    func testResolveCuratedByNameAndMiss() {
        let hit = RagaCatalog.resolveCurated(name: "KALYANI",
                                             aro: ["S"], ava: ["S"])
        XCTAssertEqual(hit?.id, "kalyani") // name match is case-insensitive
        XCTAssertNil(RagaCatalog.resolveCurated(name: "No Such Raga",
                                                aro: ["S", "R1"], ava: ["S"]))
    }

    func testPickerListIsAroOrderThenAvaOnly() {
        // Bhairavi: aro S R2 G2 M1 P D2 N2; ava adds D1.
        let bhairavi = try! XCTUnwrap(RagaCatalog.curatedRaga(id: "bhairavi"))
        XCTAssertEqual(RagaCatalog.pickerList(for: bhairavi),
                       ["S", "R2", "G2", "M1", "P", "D2", "N2", "D1"])
        XCTAssertEqual(RagaCatalog.registryId(forName: "Ahir Bhairav"), "rb-ahir-bhairav")
        XCTAssertEqual(RagaCatalog.registryId(forName: "  Desh!! "), "rb-desh")
    }

    // MARK: - P1: loops backup v3

    private func v3Plan(_ json: String, duration: Double = 60) -> (loops: [LoopsBackup.PlannedLoop], groups: [LoopsBackup.PlannedGroup])? {
        LoopsBackupV3.planImport(data: Data(json.utf8), duration: duration,
                                 isKnownRaga: { RagaCatalog.curatedRaga(id: $0) != nil })
    }

    func testLoopsBackupV3RoundTrip() {
        let phrase = Phrase(ragaId: "mohanam", saOffset: 2, tempo: 84, loop: true, chips: [
            .note([StackEntry(st: "S", oct: 0)], beats: 1), .hold(beats: 1),
        ])
        let loopID = UUID(), groupID = UUID()
        let data = LoopsBackupV3.makeData(
            songTitle: "Song",
            loops: [.init(id: loopID, name: "A", note: "n", start: 1.234, end: 5.678, phrase: phrase)],
            groups: [.init(id: groupID, name: "G", colorHex: "not-a-color", memberIDs: [loopID])],
            isKnownRaga: { RagaCatalog.curatedRaga(id: $0) != nil })
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.contains("\"version\" : 3") || text.contains("\"version\": 3"))
        let plan = try! XCTUnwrap(v3Plan(text))
        XCTAssertEqual(plan.loops.count, 1)
        XCTAssertEqual(plan.loops[0].start, 1.23) // 2dp rounding in the file
        XCTAssertEqual(plan.loops[0].phrase, phrase)
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertEqual(plan.groups[0].colorHex, "#2dd4bf") // invalid colour → palette[0] on export
        XCTAssertEqual(plan.groups[0].memberIDs, [plan.loops[0].id])
    }

    func testLoopsBackupV3ImportRules() {
        // Non-object / missing loops array → unusable.
        XCTAssertNil(v3Plan(#"{"song":"x"}"#))
        let plan = try! XCTUnwrap(v3Plan(#"""
        {"app":"Other","version":99,"loops":[
          {"id":1,"name":"ok","start":2,"end":5},
          {"id":2,"name":"degenerate","start":5,"end":5.1},
          {"id":3,"name":"beyond","start":55,"end":90},
          {"name":"no key","start":0,"end":1}
        ],"groups":[
          {"id":9,"name":"G","color":"red","members":[1,2,3,404]}
        ]}
        """#))
        // Degenerate skipped; beyond-duration clamped to 60 (kept: 55...60).
        XCTAssertEqual(plan.loops.count, 3)
        XCTAssertEqual(plan.loops[1].end, 60)
        // Group colour falls back by raw group index; dangling member 404
        // dropped; the degenerate loop's serial 2 resolves to nothing.
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertEqual(plan.groups[0].colorHex, "#2dd4bf")
        XCTAssertEqual(plan.groups[0].memberIDs.count, 2)
    }

    func testGroupSanitizerDepthCapAndCascade() {
        let l1 = UUID(), l2 = UUID()
        let g1 = LoopsBackup.PlannedGroup(id: UUID(), name: "outer", colorHex: "#fff000", memberIDs: [])
        let g2 = LoopsBackup.PlannedGroup(id: UUID(), name: "inner", colorHex: "#fff000", memberIDs: [])
        let g3 = LoopsBackup.PlannedGroup(id: UUID(), name: "deep", colorHex: "#fff000", memberIDs: [])
        var outer = g1, inner = g2, deep = g3
        outer.memberIDs = [inner.id]
        inner.memberIDs = [deep.id]
        deep.memberIDs = [l1, l2]
        let out = GroupSanitizer.sanitize(loopIDs: [l1, l2], groups: [outer, inner, deep])
        // Depth cap: inner (depth 1) may hold loops only → its link to
        // deep is cut; deep surfaces to top level with its loops.
        let byName = Dictionary(uniqueKeysWithValues: out.map { ($0.name, $0) })
        XCTAssertNil(byName["inner"]) // link cut → no descendant loops → dropped, cascading
        XCTAssertEqual(byName["deep"]?.memberIDs, [l1, l2])
        XCTAssertNil(byName["outer"]) // outer held only inner → dropped too
        XCTAssertEqual(out.count, 1)
    }
}

