import XCTest
import Varisai

/// Varisai Studio (P5, built before P4 Tala at the user's call):
/// data integrity against the mock source of truth, token parsing
/// and labels, the dheergam event builder, overlap factors and the
/// alankaram tala math. The web varisai player has no test
/// coverage; this suite is new, per the parity plan.
final class VarisaiTests: XCTestCase {

    func testCatalogShape() {
        let lessons = VarisaiData.lessons
        XCTAssertEqual(lessons.count, 7)
        XCTAssertEqual(lessons.map { $0.patterns.count }, [14, 12, 2, 7, 5, 5, 5])
        XCTAssertEqual(lessons.reduce(0) { $0 + $1.patterns.count }, 50)
        XCTAssertEqual(lessons.reduce(0) { $0 + $1.patterns.reduce(0) { $0 + $1.notes.count } },
                       3914)
        XCTAssertTrue(lessons.allSatisfy { $0.raga == "Mayamalavagowla" })
        var distinct = Set<String>()
        var laya = 0, tala = 0
        for lesson in lessons {
            for pattern in lesson.patterns {
                distinct.formUnion(pattern.notes)
                XCTAssertFalse(pattern.laya != nil && pattern.tala != nil,
                               "laya and tala are exclusive: \(pattern.title)")
                if pattern.laya != nil { laya += 1 }
                if pattern.tala != nil { tala += 1 }
                // The grouped display flattens exactly to the notes.
                let flat = pattern.dlines.flatMap { $0.flatMap { $0 } }
                XCTAssertEqual(flat, pattern.notes, pattern.title)
            }
        }
        XCTAssertEqual(distinct.count, 17)
        XCTAssertEqual(laya, 24)
        XCTAssertEqual(tala, 7)
    }

    func testTokenParsingAndSemitones() {
        XCTAssertEqual(VarisaiToken.parse(","), .hold)
        XCTAssertEqual(VarisaiToken.parse("G3"), .note(sthana: "G3", octave: 0))
        XCTAssertEqual(VarisaiToken.parse("R1'"), .note(sthana: "R1", octave: 1))
        XCTAssertEqual(VarisaiToken.parse(",D1"), .note(sthana: "D1", octave: -1))
        XCTAssertNil(VarisaiToken.semitone(",", saOffset: 0))
        XCTAssertEqual(VarisaiToken.semitone("S", saOffset: 0), 0)
        XCTAssertEqual(VarisaiToken.semitone(",M1", saOffset: 0), -7)
        XCTAssertEqual(VarisaiToken.semitone("S'", saOffset: 2), 14)
    }

    func testLabels() {
        XCTAssertEqual(VarisaiToken.label("R1", full: false), "R")
        XCTAssertEqual(VarisaiToken.label("R1", full: true), "R₁")
        XCTAssertEqual(VarisaiToken.label("G3", full: true), "G₃")
        XCTAssertEqual(VarisaiToken.label("S", full: true), "S")
        XCTAssertEqual(VarisaiToken.label("S'", full: false), "S'")
        XCTAssertEqual(VarisaiToken.label(",D1", full: true), "D\u{0323}₁")
        XCTAssertEqual(VarisaiToken.label(",P", full: false), "P\u{0323}")
        XCTAssertEqual(VarisaiToken.label(",", full: true), ",")
    }

    func testDheergamEvents() {
        let events = VarisaiPlayback.events(notes: ["S", ",", "R1"], saOffset: 0)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0], VarisaiEvent(semitone: 0, startStep: 0, slots: 2))
        XCTAssertEqual(events[1], VarisaiEvent(semitone: 1, startStep: 2, slots: 1))
        // A leading hold has no note to extend and sounds nothing.
        let leading = VarisaiPlayback.events(notes: [",", "S"], saOffset: 0)
        XCTAssertEqual(leading, [VarisaiEvent(semitone: 0, startStep: 1, slots: 1)])
        // The first Sarali pattern is the plain scale, 16 events.
        let sarali = VarisaiData.lessons[0].patterns[0]
        let scale = VarisaiPlayback.events(notes: sarali.notes, saOffset: 0)
        XCTAssertEqual(scale.map { $0.semitone },
                       [0, 1, 4, 5, 7, 8, 11, 12, 12, 11, 8, 7, 5, 4, 1, 0])
    }

    func testOverlapFactors() {
        XCTAssertEqual(VarisaiPlayback.overlap(speed: 8, step: 0.125), 2.0)
        XCTAssertEqual(VarisaiPlayback.overlap(speed: 8, step: 0.25), 2.0)
        XCTAssertEqual(VarisaiPlayback.overlap(speed: 4, step: 0.25), 1.8)
        XCTAssertEqual(VarisaiPlayback.overlap(speed: 2, step: 0.25), 1.6, accuracy: 0.001)
        XCTAssertEqual(VarisaiPlayback.overlap(speed: 1, step: 0.5), 1.15, accuracy: 0.001)
    }

    func testTalaBeats() {
        XCTAssertEqual(VarisaiPlayback.talaBeats("I4 0 I4 I4"), 14)
        XCTAssertEqual(VarisaiPlayback.talaBeats("I7 U 0"), 10)
        XCTAssertEqual(VarisaiPlayback.talaBeats("0 I4"), 6)
        XCTAssertEqual(VarisaiPlayback.talaBeats("I4"), 4)
        let alankaram = VarisaiData.lessons.first { $0.id == "alankaram" }!
        XCTAssertEqual(alankaram.patterns.compactMap { $0.tala },
                       ["I4 0 I4 I4", "I4 0 I4", "0 I4", "I7 U 0",
                        "I3 0 0", "I5 I5 0 0", "I4"])
    }

    // MARK: - Laya parsing + anga beats (web layaDisplay/talaDisplay)

    func testLayaParsePlainRunIsOneGroup() {
        XCTAssertEqual(LayaParts.parse("12345678"), [["12345678"]])
        XCTAssertEqual(LayaParts.parse("1234 5678"), [["12345678"]])
    }

    func testLayaParseGroupsAndParts() {
        XCTAssertEqual(LayaParts.parse("11-22-33-44"), [["11", "22", "33", "44"]])
        XCTAssertEqual(LayaParts.parse("11-22 and 33-44"),
                       [["11", "22"], ["33", "44"]])
    }

    func testLayaParseStripsCountHints() {
        XCTAssertEqual(LayaParts.parse("1122 (4 counts)"), [["1122"]])
    }

    func testAngaBeatsFollowTheWebRules() {
        XCTAssertEqual(VarisaiPlayback.angaBeats("I4 0 I4 I4"), [4, 2, 4, 4])
        XCTAssertEqual(VarisaiPlayback.angaBeats("I3 U"), [3, 1])
        XCTAssertEqual(VarisaiPlayback.talaBeats("I4 0 I4 I4"), 14)
    }
}
