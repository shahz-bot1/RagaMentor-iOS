import XCTest
import RagaCore
import PersistenceKit
import AudioKit
import SwaraEditor

// SwaraEditor tests (P1) — translations of the web swaras suite's
// editor behaviours: auto-save rules, the picker state machine (append,
// stack, edit with live length), and raw-JSON apply/reject. Playback
// timing itself is covered by the RagaCore expansion tests; the player
// here uses a fake tone engine.
final class SwaraEditorTests: XCTestCase {
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

    private var library: DefaultRagaLibrary!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var player: PhrasePlayer!
    private var saved: [Phrase] = []
    private var deleted = false
    private var songRaga: [String?] = []

    override func setUp() async throws {
        suiteName = "swaraed-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        library = DefaultRagaLibrary(defaults: defaults)
        saved = []
        deleted = false
        songRaga = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    private func makeModel(phrase: Phrase, hadSaved: Bool) -> SwaraEditorModel {
        let tone = FakeTone()
        player = PhrasePlayer(tone: tone)
        return SwaraEditorModel(
            phrase: phrase,
            hadSavedPhrase: hadSaved,
            contextKey: "editor:test",
            library: library,
            player: player,
            onSave: { [weak self] p in self?.saved.append(p) },
            onDelete: { [weak self] in self?.deleted = true },
            onSongRaga: { [weak self] id in self?.songRaga.append(id) })
    }

    private var emptyPhrase: Phrase {
        Phrase(ragaId: "mohanam", saOffset: 0, tempo: 72, loop: false, chips: [])
    }

    @MainActor
    func testNeverSavedEmptyPhraseStaysUnsaved() {
        let model = makeModel(phrase: emptyPhrase, hadSaved: false)
        model.setTempo(90)
        model.setSaOffset(3)
        XCTAssertTrue(saved.isEmpty) // setup edits alone do not create a phrase
        model.openAppendPicker()
        model.pickerTapSthana("S")
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.last?.chips.count, 1)
        // Emptying a now-saved phrase saves the empty phrase.
        model.openEditPicker(index: 0)
        model.pickerTapClear()
        XCTAssertEqual(model.phrase.chips.count, 0)
        XCTAssertEqual(saved.last?.chips.count, 0)
    }

    @MainActor
    func testAppendPickerStackFlowAndBeats() {
        let model = makeModel(phrase: emptyPhrase, hadSaved: false)
        model.openAppendPicker()
        model.pickerSetBeats(2)
        model.pickerToggleStack()
        model.pickerTapSthana("S")
        model.pickerTapHold()
        model.pickerTapSthana("R2")
        XCTAssertEqual(model.picker?.selection.count, 3)
        model.pickerDone()
        XCTAssertNil(model.picker)
        let chip = model.phrase.chips.first
        XCTAssertEqual(chip?.kind, .note)
        XCTAssertEqual(chip?.stack.count, 3)
        XCTAssertEqual(chip?.beats, 2)
        // Clear in append mode is a no-op that just closes the picker.
        model.openAppendPicker()
        model.pickerTapClear()
        XCTAssertEqual(model.phrase.chips.count, 1)
        XCTAssertNil(model.picker)
    }

    @MainActor
    func testEditPickerStepperWritesLive() {
        let phrase = Phrase(ragaId: nil, saOffset: 0, tempo: 60, loop: false,
                            chips: [.note([StackEntry(st: "S", oct: 0)], beats: 1)])
        let model = makeModel(phrase: phrase, hadSaved: true)
        model.openEditPicker(index: 0)
        model.pickerSetBeats(2.5)
        XCTAssertEqual(model.phrase.chips[0].beats, 2.5) // live, before any pick
        XCTAssertEqual(saved.last?.chips[0].beats, 2.5)   // and saved
        // A single pick replaces the chip, keeping the (live) beats.
        model.pickerTapSthana("P")
        XCTAssertEqual(model.phrase.chips[0].stack.first?.st, "P")
        XCTAssertEqual(model.phrase.chips[0].beats, 2.5)
    }

    @MainActor
    func testInsertPickerSplices() {
        let phrase = Phrase(ragaId: nil, saOffset: 0, tempo: 60, loop: false, chips: [
            .note([StackEntry(st: "S", oct: 0)], beats: 1),
            .note([StackEntry(st: "P", oct: 0)], beats: 1),
        ])
        let model = makeModel(phrase: phrase, hadSaved: true)
        model.openEditPicker(index: 0)
        model.openInsertPicker(before: false)
        model.pickerTapGap()
        XCTAssertEqual(model.phrase.chips.count, 3)
        XCTAssertEqual(model.phrase.chips[1].kind, .gap)
    }

    @MainActor
    func testRawJSONApplyAndReject() {
        let model = makeModel(phrase: emptyPhrase, hadSaved: true)
        model.enterRawMode()
        XCTAssertTrue(model.rawText.contains("\"ragaId\": \"mohanam\""))
        model.rawText = #"{"ragaId":"kalyani","saOffset":1,"tempo":80,"loop":true,"chips":[{"k":"note","stack":[{"st":"S","oct":0}],"beats":1}]}"#
        XCTAssertNil(model.applyRawJSON())
        XCTAssertEqual(model.phrase.ragaId, "kalyani")
        XCTAssertEqual(songRaga.last ?? nil, "kalyani")
        XCTAssertFalse(model.rawMode)
        // Invalid JSON and invalid phrases are rejected with a message.
        model.enterRawMode()
        model.rawText = "{not json"
        XCTAssertNotNil(model.applyRawJSON())
        model.rawText = #"{"chips":[{"k":"note","stack":[{"st":"ZZ","oct":0}],"beats":1}]}"#
        XCTAssertNotNil(model.applyRawJSON())
        XCTAssertTrue(model.rawMode) // still in raw mode after a failed apply
    }

    @MainActor
    func testSetRagaRecordsUseAndSongMemory() {
        let model = makeModel(phrase: emptyPhrase, hadSaved: true)
        model.setRaga(id: "kalyani")
        XCTAssertEqual(songRaga.last ?? nil, "kalyani")
        XCTAssertEqual(library.recentRagas().map(\.id), ["kalyani"])
        model.setRaga(id: nil) // Chromatic: song memory follows, recents unchanged
        XCTAssertEqual(songRaga.count, 2)
        XCTAssertNil(songRaga.last ?? "x")
        XCTAssertEqual(library.recentRagas().map(\.id), ["kalyani"])
    }

    @MainActor
    func testRawTextFormat() {
        let phrase = Phrase(ragaId: nil, saOffset: 0, tempo: 60, loop: false, chips: [
            .note([StackEntry(st: "R2", oct: -1)], beats: 0.5),
            .hold(beats: 1),
        ])
        let text = SwaraEditorModel.rawText(for: phrase)
        XCTAssertTrue(text.hasPrefix("{\n  \"ragaId\": null,"))
        XCTAssertTrue(text.contains("\"chips\": [\n    {\"k\":\"note\""))
        XCTAssertTrue(text.contains("\"stack\":[{\"st\":\"R2\",\"oct\":-1}]"))
    }
}
