import XCTest
import RagaCore
import PersistenceKit

// RagaLibrary tests (P1) — translations of the web raga-link suite:
// recents MRU, pick resolution, the favourites↔registry bridge, and the
// dropdown grouping rules. Each test runs against an isolated
// UserDefaults suite.
final class RagaLibraryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var library: DefaultRagaLibrary!
    private var suiteName: String!

    override func setUp() {
        suiteName = "ragalib-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        library = DefaultRagaLibrary(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testRecentsMRUCapFive() {
        for id in ["mohanam", "kalyani", "hindolam", "abhogi", "bhairavi", "hamsadhvani"] {
            library.recordUse(id: id)
        }
        XCTAssertEqual(library.recentRagas().map(\.id),
                       ["hamsadhvani", "bhairavi", "abhogi", "hindolam", "kalyani"])
        library.recordUse(id: "hindolam") // re-use moves to front, no dup
        XCTAssertEqual(library.recentRagas().map(\.id).first, "hindolam")
        XCTAssertEqual(library.recentRagas().count, 5)
        library.recordUse(id: "") // empty id is ignored (web guard)
        XCTAssertEqual(library.recentRagas().count, 5)
    }

    func testAdoptPickResolvesToTableBySignature() {
        // Dheerasankarabharanam (mel029) carries the Shankarabharanam
        // scale: the pick returns the table id and writes NO registry
        // entry (web raga-link: mel29 pick → table id).
        let mel29 = RagaCatalog.catalogRaga(id: "mel029")!
        let id = library.adoptPick(RagaPick(sourceId: "mel029", name: mel29.name,
                                            aro: mel29.aro, ava: mel29.ava))
        XCTAssertEqual(id, "shankarabharanam")
        XCTAssertTrue(library.registryRagas().isEmpty)
    }

    func testAdoptPickRegistersUnknownRaga() {
        let desh = RagaCatalog.catalogRaga(id: "desh")!
        let id = library.adoptPick(RagaPick(sourceId: "desh", name: desh.name,
                                            aro: desh.aro, ava: desh.ava))
        XCTAssertEqual(id, "rb-desh")
        XCTAssertEqual(library.raga(id: "rb-desh")?.name, "Desh")
        // The stored scale is normalised (apostrophes stripped, trailing S dropped).
        XCTAssertEqual(library.raga(id: "rb-desh")?.aro.last, "N3")
        XCTAssertEqual(library.raga(id: "rb-desh")?.ava.last, "N2")
    }

    func testFavouriteBridgeAddsAndRemovesRegistryEntry() {
        let desh = RagaCatalog.catalogRaga(id: "desh")!
        XCTAssertFalse(library.isFavourite(sourceId: "desh"))
        library.setFavourite(desh, favourited: true)
        XCTAssertTrue(library.isFavourite(sourceId: "desh"))
        XCTAssertEqual(library.favourites().map(\.id), ["desh"])
        // The favourite appears in the registry (src "fav") for editors.
        XCTAssertEqual(library.registryRagas().map(\.id), ["rb-desh"])
        library.setFavourite(desh, favourited: false)
        XCTAssertFalse(library.isFavourite(sourceId: "desh"))
        XCTAssertTrue(library.registryRagas().isEmpty)
    }

    func testFavouriteThatResolvesToTableSkipsRegistry() {
        // Favouriting mel029 mirrors the data, but sync skips it: the
        // scale resolves to the curated table (web syncFavRegistry).
        let mel29 = RagaCatalog.catalogRaga(id: "mel029")!
        library.setFavourite(mel29, favourited: true)
        XCTAssertTrue(library.isFavourite(sourceId: "mel029"))
        XCTAssertTrue(library.registryRagas().isEmpty)
    }

    func testUnfavouriteKeepsPickEntries() {
        // A raga adopted by pick (src "pick") must survive an
        // unfavourite of the same-named browser raga (web rule).
        let desh = RagaCatalog.catalogRaga(id: "desh")!
        library.setFavourite(desh, favourited: true)
        let id = library.adoptPick(RagaPick(sourceId: "desh", name: desh.name,
                                            aro: desh.aro, ava: desh.ava))
        XCTAssertEqual(id, "rb-desh")
        library.setFavourite(desh, favourited: false)
        XCTAssertEqual(library.raga(id: "rb-desh")?.name, "Desh")
    }

    func testDropdownGroupsPinCurrentAndDedupe() {
        library.recordUse(id: "kalyani")
        let desh = RagaCatalog.catalogRaga(id: "desh")!
        library.adoptPick(RagaPick(sourceId: "desh", name: desh.name,
                                   aro: desh.aro, ava: desh.ava))
        // Current (mohanam) is in neither group → pinned at Recents front.
        var groups = library.dropdownGroups(currentId: "mohanam")
        XCTAssertEqual(groups.recents.map(\.id), ["mohanam", "kalyani"])
        XCTAssertEqual(groups.favourites.map(\.id), ["rb-desh"])
        // Current already in recents → no duplicate pin.
        groups = library.dropdownGroups(currentId: "kalyani")
        XCTAssertEqual(groups.recents.map(\.id), ["kalyani"])
        // A registry raga in recents leaves the Favourites group.
        library.recordUse(id: "rb-desh")
        groups = library.dropdownGroups(currentId: nil)
        XCTAssertEqual(groups.recents.map(\.id), ["rb-desh", "kalyani"])
        XCTAssertTrue(groups.favourites.isEmpty)
    }
}
