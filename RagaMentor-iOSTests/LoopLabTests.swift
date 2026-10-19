import XCTest
import SwiftData
import AVFoundation
import LoopLab
import PersistenceKit
import AudioKit
import RagaCore

// LoopLab tests (PARITY-PLAN §6: the v0.6.0 suite, split per module in P0).
final class LoopLabTests: XCTestCase {

    func testStoredFileName() {
        XCTAssertEqual(ImportService.storedFileName(hash: "abc123", sourceExtension: "MP3"), "abc123.mp3")
        XCTAssertEqual(ImportService.storedFileName(hash: "abc123", sourceExtension: ""), "abc123")
        XCTAssertEqual(ImportService.relativePath(hash: "abc123", sourceExtension: "m4a"), "Audio/abc123.m4a")
    }

    func testWaveformWindowMath() {
        var w = WaveformWindow(duration: 100)
        XCTAssertEqual(w.length, 100)
        XCTAssertEqual(w.time(forX: 50, width: 200), 25)
        XCTAssertEqual(w.x(forTime: 25, width: 200), 50)

        // Zoom in around 50s to a 10s window, centred on the focal point.
        w = w.zoomed(by: 0.1, around: 50)
        XCTAssertEqual(w.length, 10, accuracy: 1e-9)
        XCTAssertEqual(w.start, 45, accuracy: 1e-9)

        // Cannot zoom past the 2s floor.
        let floor = w.zoomed(by: 0.0001, around: 50)
        XCTAssertEqual(floor.length, WaveformWindow.minLength, accuracy: 1e-9)

        // Panning clamps at both ends.
        XCTAssertEqual(w.panned(by: -1000).start, 0)
        XCTAssertEqual(w.panned(by: 1000).start, 90, accuracy: 1e-9)

        // Follow: no move while visible; minimal shift when outside.
        XCTAssertEqual(w.following(47), w)
        let shifted = w.following(80)
        XCTAssertTrue(shifted.start <= 80 && shifted.end >= 80)
    }
}

// MARK: - Single-playback funnel (v1.5.11)

/// The song-start funnel: starting the song from ANY entry point
/// stops a playing swara phrase and fires the focus hook.
/// selectLoop and selectGroup used to call the engine directly,
/// bypassing the check (his bug report: a phrase playing + tap a
/// loop chip = both sounded).
@MainActor
final class PlaybackFunnelTests: XCTestCase {
    private final class NullTone: ToneEngine {
        func prepare() async {}
        func playNote(semitone: Int, atOffset offset: Double, duration: Double) {}
        func stopAll() {}
    }

    private var container: ModelContainer!
    private var audioURL: URL!

    override func setUp() async throws {
        container = try ModelContainer(
            for: Song.self, LoopRegion.self, LoopGroup.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        // A one-second silent WAV for the engine to load, at the
        // path the Song points at.
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        audioURL = dir.appendingPathComponent("funnel-test.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let frames = AVAudioFrameCount(44100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        try file.write(from: buffer)
    }

    override func tearDown() {
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
    }

    private func makeScene() throws -> (controller: PlaybackController, song: Song, loop: LoopRegion) {
        let context = ModelContext(container)
        let loop = LoopRegion(name: "Loop 1", start: 0.1, end: 0.8)
        let song = Song(title: "Funnel", contentHash: "funnel",
                        fileRelativePath: "Audio/funnel-test.wav",
                        duration: 1, sampleRate: 44100, loops: [loop])
        loop.song = song
        context.insert(song)
        try context.save()
        let controller = PlaybackController(
            sequencePlayer: SequencePlayer(tone: NullTone()))
        controller.open(song)
        XCTAssertNotNil(controller.currentSong, "the test song did not open")
        return (controller, song, loop)
    }

    @discardableResult
    private func waitFor(_ seconds: Double = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func startPhrase(_ controller: PlaybackController) {
        let phrase = Phrase(ragaId: nil, saOffset: 0, tempo: 60, loop: true, chips: [
            .note([StackEntry(st: "S", oct: 0)], beats: 1),
            .note([StackEntry(st: "P", oct: 0)], beats: 1),
        ])
        controller.phraseAdapter.play(
            phrase: phrase, contextKey: "section:test", contextValid: { true })
        XCTAssertTrue(
            waitFor { controller.phraseAdapter.isPlaying(contextKey: "section:test") },
            "the phrase did not start")
    }

    func testSelectLoopStopsAPlayingPhrase() throws {
        let (controller, _, loop) = try makeScene()
        var focusFired = false
        controller.onSongStart = { focusFired = true }
        startPhrase(controller)
        controller.selectLoop(loop, context: ModelContext(container))
        XCTAssertFalse(controller.phraseAdapter.isPlaying(contextKey: "section:test"),
                       "tapping a loop must stop the playing phrase")
        XCTAssertTrue(focusFired, "a song start must fire the focus hook")
        XCTAssertTrue(controller.isPlaying)
    }

    func testSelectGroupStopsAPlayingPhrase() throws {
        let (controller, song, loop) = try makeScene()
        let context = ModelContext(container)
        let group = LoopGroup(name: "Group 1", memberIDs: [loop.id], song: song)
        song.groups = [group]
        context.insert(group)
        try context.save()
        var focusFired = false
        controller.onSongStart = { focusFired = true }
        startPhrase(controller)
        controller.selectGroup(group, context: context)
        XCTAssertFalse(controller.phraseAdapter.isPlaying(contextKey: "section:test"),
                       "tapping a group must stop the playing phrase")
        XCTAssertTrue(focusFired, "a song start must fire the focus hook")
        XCTAssertTrue(controller.isPlaying)
    }
}
