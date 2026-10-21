import XCTest
import Combine
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
        var samplesReady = true
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
        // Fit-on-select (v1.5.12): the tap also asks the waveform
        // to zoom to the loop.
        XCTAssertEqual(controller.zoomRequest?.start, 0.1)
        XCTAssertEqual(controller.zoomRequest?.end, 0.8)
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
        XCTAssertEqual(controller.zoomRequest?.start, 0.1)
        XCTAssertEqual(controller.zoomRequest?.end, 0.8)
    }
}

// MARK: - Waveform fit-on-select (v1.5.12)

final class WaveformFittingTests: XCTestCase {
    func testFitting() {
        let w = WaveformWindow(duration: 100)
        // A range fits exactly.
        var f = w.fitting(from: 40, to: 50)
        XCTAssertEqual(f.length, 10, accuracy: 1e-9)
        XCTAssertEqual(f.start, 40, accuracy: 1e-9)
        // Below the 2 s floor: the window takes the floor length,
        // centred on the range.
        f = w.fitting(from: 40, to: 40.5)
        XCTAssertEqual(f.length, 2, accuracy: 1e-9)
        XCTAssertEqual(f.start, 39.25, accuracy: 1e-9)
        // At the start edge the window clamps to 0.
        f = w.fitting(from: 0, to: 0.5)
        XCTAssertEqual(f.length, 2, accuracy: 1e-9)
        XCTAssertEqual(f.start, 0, accuracy: 1e-9)
        // At the end edge it clamps so the window ends with the song.
        f = w.fitting(from: 99.5, to: 100)
        XCTAssertEqual(f.length, 2, accuracy: 1e-9)
        XCTAssertEqual(f.start, 98, accuracy: 1e-9)
        XCTAssertEqual(f.end, 100, accuracy: 1e-9)
        // A long range fits exactly.
        f = w.fitting(from: 10, to: 90)
        XCTAssertEqual(f.length, 80, accuracy: 1e-9)
        XCTAssertEqual(f.start, 10, accuracy: 1e-9)
    }
}

// MARK: - New-group flow (v1.5.12)

/// The web's group rules: instant creation with auto-name and
/// palette colour, and the checklist's level-constrained
/// candidates.
@MainActor
final class GroupFlowTests: XCTestCase {
    private final class NullTone: ToneEngine {
        var samplesReady = true
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
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        audioURL = dir.appendingPathComponent("funnel-test.wav")
        if !FileManager.default.fileExists(atPath: audioURL.path) {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            let frames = AVAudioFrameCount(44100)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try file.write(from: buffer)
        }
    }

    /// Loops A 10–20, B 30–40, C 50–60, D 70–80. Groups: G1 (flat,
    /// top level) holds A; Sub (flat) holds C; Host (top level,
    /// NOT flat) holds Sub and D.
    private func makeLibrary() throws -> (PlaybackController, Song) {
        let context = ModelContext(container)
        let a = LoopRegion(name: "A", start: 10, end: 20)
        let b = LoopRegion(name: "B", start: 30, end: 40)
        let c = LoopRegion(name: "C", start: 50, end: 60)
        let d = LoopRegion(name: "D", start: 70, end: 80)
        let sub = LoopGroup(name: "Sub", memberIDs: [c.id])
        let g1 = LoopGroup(name: "G1", memberIDs: [a.id])
        let host = LoopGroup(name: "Host", memberIDs: [sub.id, d.id])
        let song = Song(title: "Groups", contentHash: "groups",
                        fileRelativePath: "Audio/funnel-test.wav",
                        duration: 100, sampleRate: 44100,
                        loops: [a, b, c, d], groups: [g1, sub, host])
        for loop in [a, b, c, d] { loop.song = song }
        for g in [g1, sub, host] { g.song = song }
        context.insert(song)
        try context.save()
        let controller = PlaybackController(
            sequencePlayer: SequencePlayer(tone: NullTone()))
        controller.open(song)
        XCTAssertNotNil(controller.currentSong, "the test song did not open")
        return (controller, song)
    }

    private func group(_ song: Song, _ name: String) -> LoopGroup {
        song.groups.first { $0.name == name }!
    }
    private func loop(_ song: Song, _ name: String) -> LoopRegion {
        song.loops.first { $0.name == name }!
    }

    func testNextGroupNameCountsUpPastUsedNames() {
        XCTAssertEqual(PlaybackController.nextGroupName(existing: []), "Group 1")
        XCTAssertEqual(PlaybackController.nextGroupName(existing: ["Group 1"]), "Group 2")
        XCTAssertEqual(PlaybackController.nextGroupName(existing: ["Group 2"]), "Group 3")
        XCTAssertEqual(PlaybackController.groupPalette[0], "#2dd4bf")
    }

    func testCreateGroupAutoNamesColoursAndFilesInsideParent() throws {
        let (controller, song) = try makeLibrary()
        let context = ModelContext(container)
        let created = try XCTUnwrap(controller.createGroup(context: context))
        XCTAssertEqual(created.name, "Group 4") // 3 groups exist; first free from 4
        XCTAssertEqual(created.colorHex, "#fb7185") // palette[3]
        XCTAssertTrue(created.memberIDs.isEmpty)
        let child = try XCTUnwrap(controller.createGroup(inside: created, context: context))
        XCTAssertEqual(child.name, "Group 5")
        XCTAssertEqual(child.colorHex, "#38bdf8") // palette[4]
        XCTAssertTrue(created.memberIDs.contains(child.id),
                      "the child is filed inside its parent")
    }

    func testCandidatesForNewTopLevelGroupAreTheVisibleItems() throws {
        let (controller, song) = try makeLibrary()
        let context = ModelContext(container)
        let created = try XCTUnwrap(controller.createGroup(context: context))
        let ids = controller.checklistCandidateIDs(for: created, isNew: true)
        // Visible at top level: G1 (flat, parentless; sorts by its
        // range start, 10) and the ungrouped loop B (30). A is
        // inside G1, C inside Sub, D inside Host; Sub is flat but
        // has a parent; Host is not flat; the new group itself is
        // never a candidate.
        XCTAssertEqual(ids, [group(song, "G1").id, loop(song, "B").id])
    }

    func testCandidatesForNewSubGroupAreTheParentsDirectLoops() throws {
        let (controller, song) = try makeLibrary()
        let context = ModelContext(container)
        let created = try XCTUnwrap(controller.createGroup(inside: group(song, "Host"), context: context))
        let ids = controller.checklistCandidateIDs(for: created, isNew: true)
        // Host's direct member loops: only D. C lives inside Sub —
        // a sibling sub-group's loops are not visible at this level.
        XCTAssertEqual(ids, [loop(song, "D").id])
    }

    func testCandidatesForExistingGroupsFollowTheReorganizeRules() throws {
        let (controller, song) = try makeLibrary()
        // Existing top-level group: every loop, plus flat parentless
        // groups — Sub has a parent, Host is not flat, G1 excludes
        // itself.
        let g1IDs = controller.checklistCandidateIDs(for: group(song, "G1"), isNew: false)
        XCTAssertEqual(g1IDs, [loop(song, "A").id, loop(song, "B").id,
                               loop(song, "C").id, loop(song, "D").id])
        // Existing sub-group: loops only (sub-groups hold loops only).
        let subIDs = controller.checklistCandidateIDs(for: group(song, "Sub"), isNew: false)
        XCTAssertEqual(subIDs, [loop(song, "A").id, loop(song, "B").id,
                                loop(song, "C").id, loop(song, "D").id])
        // Existing Host (top level, holds a group): loops + G1.
        // (G1's range starts where A starts, so their relative
        // order is a tie — assert membership + the loops' order.)
        let hostIDs = controller.checklistCandidateIDs(for: group(song, "Host"), isNew: false)
        XCTAssertEqual(hostIDs.count, 5)
        XCTAssertTrue(hostIDs.contains(group(song, "G1").id))
        XCTAssertEqual(hostIDs.filter { id in song.loops.contains { $0.id == id } },
                       [loop(song, "A").id, loop(song, "B").id,
                        loop(song, "C").id, loop(song, "D").id])
    }
}

/// Loop notes are multiline (v1.5.20, web parity): the storage
/// layer must keep line breaks verbatim — the editor is a
/// growing multiline field, and the web format carries the
/// same breaks.
final class LoopNoteTests: XCTestCase {
    private final class NullTone: ToneEngine {
        var samplesReady = true
        func prepare() async {}
        func playNote(semitone: Int, atOffset offset: Double, duration: Double) {}
        func stopAll() {}
    }

    @MainActor
    func testLoopNoteStoresMultilineVerbatim() throws {
        let container = try ModelContainer(
            for: Song.self, LoopRegion.self, LoopGroup.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let song = Song(title: "T", contentHash: "h",
                        fileRelativePath: "Audio/x.wav", duration: 60,
                        sampleRate: 44100)
        let loop = LoopRegion(name: "L", start: 1, end: 5, song: song)
        context.insert(song)
        context.insert(loop)
        try context.save()
        let controller = PlaybackController(
            sequencePlayer: SequencePlayer(tone: NullTone()))
        controller.setLoopNote(loop,
                               to: "key of D\nsa lands on beat 3\nwatch the G3",
                               context: context)
        let fetched = try context.fetch(FetchDescriptor<LoopRegion>())
        XCTAssertEqual(fetched.first?.note,
                       "key of D\nsa lands on beat 3\nwatch the G3")
    }
}

/// Follow tolerance (v1.5.20): the fitted window's start is the
/// loop start; a seek landing a frame early must not page the
/// window (the badge-tap displacement), while a genuinely
/// outside playhead still pages as before.
final class WaveformFollowingTests: XCTestCase {
    func testFollowingTolerance() {
        let w = WaveformWindow(duration: 100).fitting(from: 40, to: 50)
        XCTAssertEqual(w.start, 40, accuracy: 1e-9)
        // A frame early, and a hair past the end: still.
        XCTAssertEqual(w.following(39.999).start, 40, accuracy: 1e-9)
        XCTAssertEqual(w.following(39.96).start, 40, accuracy: 1e-9)
        XCTAssertEqual(w.following(50.04).start, 40, accuracy: 1e-9)
        // Genuinely outside: pages to 10% in, as before.
        XCTAssertEqual(w.following(39.9).start, 38.9, accuracy: 1e-9)
        XCTAssertEqual(w.following(50.2).start, 49.2, accuracy: 1e-9)
        // Comfortably inside: untouched.
        XCTAssertEqual(w.following(45).start, 40, accuracy: 1e-9)
    }
}

/// Armed-range hold (v1.5.21): while a fitted loop/group stays
/// armed, follow never moves the window — for playhead reports
/// inside the range, at its seam, or wildly outside it
/// (scheduling-transition noise). Without a hold, the classic
/// behaviour is untouched.
final class WaveformHoldTests: XCTestCase {
    func testHoldNeverPages() {
        let w = WaveformWindow(duration: 100).fitting(from: 40, to: 50)
        let hold = (start: 40.0, end: 50.0)
        for t in [0.0, 39.9, 40.0, 45.0, 49.999, 50.0, 50.4, 99.0] {
            XCTAssertEqual(w.following(t, holdRange: hold).start, 40,
                           accuracy: 1e-9, "t=\(t)")
        }
        // No hold: the same reports page as before.
        XCTAssertEqual(w.following(0, holdRange: nil).start, 0, accuracy: 1e-9)
        XCTAssertEqual(w.following(45, holdRange: nil).start, 40, accuracy: 1e-9)
    }
}

// MARK: - Playhead clock split (v1.5.27)

/// The scroll-jank fix's mechanism, pinned: position changes
/// publish on the playhead clock ONLY — the controller's own
/// objectWillChange must stay silent, or every view holding
/// the controller (the loops list, the transport) rebuilds at
/// 20 Hz again.
@MainActor
final class PlayheadClockTests: XCTestCase {
    private var container: ModelContainer!
    private var audioURL: URL!
    private var cancellables: [AnyCancellable] = []

    override func setUp() async throws {
        container = try ModelContainer(
            for: Song.self, LoopRegion.self, LoopGroup.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        audioURL = dir.appendingPathComponent("playhead-test.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let frames = AVAudioFrameCount(44100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        try file.write(from: buffer)
    }

    override func tearDown() {
        cancellables = []
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
    }

    private final class NullTone: ToneEngine {
        var samplesReady = true
        func prepare() async {}
        func playNote(semitone: Int, atOffset offset: Double, duration: Double) {}
        func stopAll() {}
    }

    func testSeekPublishesOnTheClockNotTheController() throws {
        let context = ModelContext(container)
        let song = Song(title: "Playhead", contentHash: "playhead",
                        fileRelativePath: "Audio/playhead-test.wav",
                        duration: 1, sampleRate: 44100, loops: [])
        context.insert(song)
        try context.save()
        let controller = PlaybackController(
            sequencePlayer: SequencePlayer(tone: NullTone()))
        controller.open(song)
        XCTAssertNotNil(controller.currentSong)

        var controllerPublished = false
        var clockPublished = false
        controller.objectWillChange
            .sink { controllerPublished = true }
            .store(in: &cancellables)
        controller.playhead.objectWillChange
            .sink { clockPublished = true }
            .store(in: &cancellables)

        controller.seek(to: 0.5)

        XCTAssertEqual(controller.position, 0.5, accuracy: 1e-9)
        XCTAssertEqual(controller.playhead.position, 0.5, accuracy: 1e-9,
                       "the clock must mirror every position change")
        XCTAssertTrue(clockPublished, "the clock must publish the tick")
        XCTAssertFalse(controllerPublished,
                       "a position change must NOT publish on the controller — that is the jank")
    }
}

// MARK: - Waveform bar aggregation (v1.5.27)

final class WaveformBarsTests: XCTestCase {
    func testUnderCapIsIdentity() {
        let peaks: [Float] = [0.1, 0.9, 0.3, 0.5]
        let bars = WaveformBars.aggregate(peaks: peaks, first: 0, last: 3, maxBars: 48)
        XCTAssertEqual(bars.count, 4)
        XCTAssertEqual(bars.map(\.peak), peaks)
        XCTAssertTrue(bars.allSatisfy { $0.span == 1 })
        XCTAssertEqual(bars.map(\.bucket), [0, 1, 2, 3])
    }

    func testOverCapAggregatesByMax() {
        let peaks = (0..<6000).map { Float($0 % 97) / 97 }
        let bars = WaveformBars.aggregate(peaks: peaks, first: 0, last: 5999, maxBars: 262)
        XCTAssertLessThanOrEqual(bars.count, 262)
        XCTAssertEqual(bars.reduce(0) { $0 + $1.span }, 6000,
                       "spans must cover the whole visible range")
        XCTAssertEqual(bars.map(\.peak).max(), peaks.max(),
                       "the tallest peak survives — the silhouette is preserved")
        // Every bar's peak is the max of its own run.
        for bar in bars {
            let run = peaks[bar.bucket..<(bar.bucket + bar.span)]
            XCTAssertEqual(bar.peak, run.max())
        }
    }

    func testSubrangeAndInvalid() {
        let peaks: [Float] = [0.2, 0.4, 0.6, 0.8, 1.0]
        let bars = WaveformBars.aggregate(peaks: peaks, first: 1, last: 3, maxBars: 2)
        XCTAssertEqual(bars.reduce(0) { $0 + $1.span }, 3)
        XCTAssertEqual(bars.first?.bucket, 1)
        XCTAssertTrue(WaveformBars.aggregate(peaks: peaks, first: 3, last: 1, maxBars: 4).isEmpty)
        XCTAssertTrue(WaveformBars.aggregate(peaks: [], first: 0, last: 0, maxBars: 4).isEmpty)
    }
}
