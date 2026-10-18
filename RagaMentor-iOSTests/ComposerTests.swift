import XCTest
import RagaCore
import PersistenceKit

/// Compose Studio (P2): composition defaults, the store's ordering
/// and persistence, and the export/import file format — the native
/// port of the web compose suite.
final class ComposerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "ComposerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testNewCompositionDefaults() {
        let comp = Composition.makeDefault(now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(comp.name, "Untitled composition")
        XCTAssertEqual(comp.phrase.ragaId, "mohanam")
        XCTAssertEqual(comp.phrase.saOffset, 0)
        XCTAssertEqual(comp.phrase.tempo, 60)
        XCTAssertFalse(comp.phrase.loop)
        XCTAssertTrue(comp.phrase.chips.isEmpty)
        XCTAssertTrue(comp.id.hasPrefix("c"))
    }

    func testStoreOrderingPersistenceAndEdits() {
        var t = Date(timeIntervalSince1970: 1000)
        let store = UserDefaultsCompositionStore(defaults: defaults, now: { t })
        let a = store.createDefault()
        t = Date(timeIntervalSince1970: 2000)
        let b = store.appendImported(name: "Second", phrase: a.phrase)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(store.all().map(\.id), [b.id, a.id]) // updatedAt desc

        // A fresh store over the same defaults sees the same data.
        let store2 = UserDefaultsCompositionStore(defaults: defaults, now: { t })
        XCTAssertEqual(store2.all().count, 2)

        // Saving a phrase stamps updatedAt: the order flips.
        t = Date(timeIntervalSince1970: 3000)
        var phrase = a.phrase
        phrase.tempo = 90
        store.save(phrase: phrase, for: a.id)
        XCTAssertEqual(store.all().first?.id, a.id)
        XCTAssertEqual(store.all().first?.phrase.tempo, 90)

        store.rename(id: b.id, to: "Renamed")
        XCTAssertEqual(store.all().first(where: { $0.id == b.id })?.name, "Renamed")

        store.delete(id: a.id)
        XCTAssertEqual(store.all().map(\.id), [b.id])
    }

    func testExportEnvelopeKeyOrderAndRoundTrip() {
        let phrase = Phrase(ragaId: "mohanam", saOffset: 0, tempo: 60, loop: false,
                            chips: [.note([StackEntry(st: "S", oct: 0)], beats: 1)])
        let data = CompositionFile.exportData(name: "My Song", phrase: phrase)
        let text = String(decoding: data, as: UTF8.self)
        // Web key order: app, version, kind, composition{name, ragaId, …}.
        XCTAssertTrue(text.hasPrefix(
            "{\n  \"app\": \"Compose Studio\",\n  \"version\": 1,\n  \"kind\": \"composition\",\n  \"composition\": {\n    \"name\": \"My Song\",\n    \"ragaId\": \"mohanam\","),
            "unexpected export head:\n\(text)")
        // The export parses back to the same name and phrase.
        switch CompositionFile.parseImport(data: data, isKnownRaga: { $0 == "mohanam" }) {
        case .success(let parsed):
            XCTAssertEqual(parsed.name, "My Song")
            XCTAssertEqual(parsed.phrase, PhraseSanitizer.sanitize(phrase: phrase, isKnownRaga: { _ in true }))
        case .failure(let error):
            XCTFail("export did not re-import: \(error)")
        }
    }

    func testImportPaths() {
        let known: (String) -> Bool = { $0 == "mohanam" }

        // A bare phrase object (no envelope, no name) is accepted.
        let bare = Data("{\"ragaId\":\"mohanam\",\"saOffset\":2,\"tempo\":80,\"loop\":true,\"chips\":[]}".utf8)
        switch CompositionFile.parseImport(data: bare, isKnownRaga: known) {
        case .success(let parsed):
            XCTAssertEqual(parsed.name, "Untitled composition")
            XCTAssertEqual(parsed.phrase.saOffset, 2)
            XCTAssertTrue(parsed.phrase.loop)
        case .failure(let error):
            XCTFail("bare import failed: \(error)")
        }

        // Bad JSON and a sanitizer failure are distinct errors (web).
        if case .failure(.invalidJSON) =
            CompositionFile.parseImport(data: Data("nope".utf8), isKnownRaga: known) {
        } else { XCTFail("expected invalidJSON") }

        let badChip = Data("{\"chips\":[{\"k\":\"note\",\"stack\":[{\"st\":\"X9\",\"oct\":0}],\"beats\":1}]}".utf8)
        if case .failure(.invalidComposition) =
            CompositionFile.parseImport(data: badChip, isKnownRaga: known) {
        } else { XCTFail("expected invalidComposition") }
    }

    func testFileSlug() {
        XCTAssertEqual(CompositionFile.fileSlug(for: "My First Song!"), "my-first-song")
        XCTAssertEqual(CompositionFile.fileSlug(for: "!!!"), "composition")
    }
}
