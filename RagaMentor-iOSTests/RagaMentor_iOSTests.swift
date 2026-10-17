import XCTest
import SwiftData
@testable import RagaMentor_iOS

final class RagaMentor_iOSTests: XCTestCase {

    // MARK: Pipeline smoke test

    func testGreetingMessage() {
        XCTAssertEqual(Greeting.message, "Hello, RagaMentor!")
    }

    // MARK: Hashing (PLAN §8 dedupe key)

    func testSHA256KnownVector() {
        // FIPS 180-4 example: SHA-256("abc")
        XCTAssertEqual(AudioHash.sha256Hex(of: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testStoredFileName() {
        XCTAssertEqual(ImportService.storedFileName(hash: "abc123", sourceExtension: "MP3"), "abc123.mp3")
        XCTAssertEqual(ImportService.storedFileName(hash: "abc123", sourceExtension: ""), "abc123")
        XCTAssertEqual(ImportService.relativePath(hash: "abc123", sourceExtension: "m4a"), "Audio/abc123.m4a")
    }

    // MARK: Time math

    func testTimeMathRoundTrip() {
        XCTAssertEqual(TimeMath.frames(forSeconds: 1.5, sampleRate: 48000), 72000)
        XCTAssertEqual(TimeMath.seconds(forFrames: 72000, sampleRate: 48000), 1.5)
        XCTAssertEqual(TimeMath.frames(forSeconds: 2, sampleRate: 0), 0)
        XCTAssertEqual(TimeMath.clamp(5, min: 0, max: 3), 3)
        XCTAssertEqual(TimeMath.clamp(-1, min: 0, max: 3), 0)
    }

    // MARK: Loop rules (PLAN §6, §12)

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

    // MARK: Group derived range (PLAN §6)

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

    // MARK: Peaks (PLAN §9)

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

    // MARK: Persistence round-trip (PLAN §11, §13)

    @MainActor
    func testSongPersistenceRoundTrip() throws {
        let container = try ModelContainer(
            for: Song.self, LoopRegion.self, LoopGroup.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext

        let hash = AudioHash.sha256Hex(of: Data("fake audio bytes".utf8))
        let song = Song(title: "Test Song",
                        contentHash: hash,
                        fileRelativePath: "Audio/\(hash).mp3",
                        duration: 120,
                        sampleRate: 44100,
                        lastPosition: 42.5)
        let loop = LoopRegion(name: "Loop 1", note: "Sa = C#", start: 10, end: 20, sortOrder: 0, song: song)
        let group = LoopGroup(name: "Pallavi", memberIDs: [loop.id], song: song)
        song.loops = [loop]
        song.groups = [group]
        context.insert(song)
        try context.save()

        // Dedupe lookup by content hash finds exactly this song.
        let byHash = try context.fetch(FetchDescriptor<Song>(predicate: #Predicate { $0.contentHash == hash }))
        XCTAssertEqual(byHash.count, 1)
        let fetched = try XCTUnwrap(byHash.first)
        XCTAssertEqual(fetched.title, "Test Song")
        XCTAssertEqual(fetched.lastPosition, 42.5)
        XCTAssertEqual(fetched.loops.count, 1)
        XCTAssertEqual(fetched.loops.first?.note, "Sa = C#")
        XCTAssertEqual(fetched.groups.first?.memberIDs, [loop.id])

        // Cascade delete removes loops and groups with the song.
        context.delete(fetched)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<LoopRegion>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LoopGroup>()).count, 0)
    }
}
