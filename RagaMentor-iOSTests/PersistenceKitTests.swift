import XCTest
import SwiftData
import PersistenceKit
import RagaCore

// PersistenceKit tests (PARITY-PLAN §6: the v0.6.0 suite, split per module in P0).
final class PersistenceKitTests: XCTestCase {

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
