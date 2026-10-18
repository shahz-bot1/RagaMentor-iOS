import XCTest
import RagaCore

/// RagaBrowser (P3): the scale walk over both catalog shapes, the
/// collapsed search classes, chakra math and the notation maps —
/// the new native suites the parity plan specified for the browser
/// (the web runtime detail has no test coverage).
final class RagaBrowserTests: XCTestCase {

    func testWalkCatalogShapeWithApostropheTop() {
        let semis = ScaleWalk.semitones(
            aro: ["S", "R2", "G3", "P", "D2", "S'"],
            ava: ["S'", "D2", "P", "G3", "R2", "S"], saOffset: 0)
        XCTAssertEqual(semis, [0, 2, 4, 7, 9, 12, 12, 9, 7, 4, 2, 0])
    }

    func testWalkCuratedShapeWithoutTopS() {
        let semis = ScaleWalk.semitones(
            aro: ["S", "R2", "G3", "P", "D2"],
            ava: ["S", "D2", "P", "G3", "R2", "S"], saOffset: 0)
        XCTAssertEqual(semis, [0, 2, 4, 7, 9, 12, 9, 7, 4, 2, 0])
    }

    func testWalkAppliesSaOffset() {
        let semis = ScaleWalk.semitones(
            aro: ["S", "P"], ava: ["S", "P", "S"], saOffset: 3)
        XCTAssertEqual(semis.first, 3)
        XCTAssertEqual(semis, [3, 10, 15, 10, 3])
    }

    func testPitchClassesFoldEnharmonics() {
        // G1 sounds pitch 2 and N1 sounds pitch 9 in the shared map.
        let pcs = ScaleWalk.pitchClasses(aro: ["S", "G1", "M1", "N1"], ava: ["S"])
        XCTAssertEqual(pcs, [0, 2, 5, 9])
    }

    func testSearchClassMatching() {
        let mohanam = RagaCatalog.all.first { $0.id == "mohanam" }!
        XCTAssertTrue(RagaSearch.matches(mohanam, nameQuery: "",
                                         selectedClasses: ["R2", "G3"]))
        XCTAssertFalse(RagaSearch.matches(mohanam, nameQuery: "",
                                          selectedClasses: ["M2"]))
        XCTAssertTrue(RagaSearch.matches(mohanam, nameQuery: "moha",
                                         selectedClasses: []))
        XCTAssertFalse(RagaSearch.matches(mohanam, nameQuery: "kalyani",
                                          selectedClasses: []))
        // A class matches by pitch: a raga holding G1 matches "R2".
        let folded = RagaCatalog.all.filter {
            RagaSearch.matches($0, nameQuery: "", selectedClasses: ["R2"])
        }
        XCTAssertTrue(folded.contains { $0.aro.contains("G1") || $0.ava.contains("G1") })
    }

    func testChakraMath() {
        XCTAssertEqual(Melakarta.chakraIndex(forNumber: 1), 0)
        XCTAssertEqual(Melakarta.chakraIndex(forNumber: 6), 0)
        XCTAssertEqual(Melakarta.chakraIndex(forNumber: 7), 1)
        XCTAssertEqual(Melakarta.chakraName(forNumber: 29), "Bana")
        XCTAssertEqual(Melakarta.chakraIndex(forNumber: 72), 11)
        let melakartas = RagaCatalog.all.filter { $0.melakartaNumber != nil }
        XCTAssertEqual(melakartas.count, 72)
        // Six ragas per chakra, M1 side in chakras 0–5, M2 in 6–11.
        for chakra in 0..<12 {
            let inChakra = melakartas.filter {
                Melakarta.chakraIndex(forNumber: $0.melakartaNumber ?? 0) == chakra
            }
            XCTAssertEqual(inChakra.count, 6, "chakra \(chakra)")
        }
    }

    func testNotationMaps() {
        XCTAssertEqual(ScaleNotation.hindustani("R1"), "r")
        XCTAssertEqual(ScaleNotation.hindustani("G3"), "G")
        XCTAssertEqual(ScaleNotation.hindustani("M2"), "M")
        XCTAssertEqual(ScaleNotation.hindustani("N1"), "n")
        XCTAssertEqual(ScaleNotation.hindustani("P"), "P")
        XCTAssertEqual(ScaleNotation.western(pitchClass: 1), "C#")
        XCTAssertEqual(ScaleNotation.western(pitchClass: 3), "Eb")
        XCTAssertEqual(ScaleNotation.western(pitchClass: 13), "C#")
    }

    func testHindustaniCatalogShape() {
        let hindustani = RagaCatalog.all.filter { $0.isHindustani }
        XCTAssertEqual(hindustani.count, 11)
        XCTAssertEqual(Set(hindustani.compactMap { $0.thaat }).count, 7)
        XCTAssertEqual(RagaCatalog.all.count, 87)
    }
}
