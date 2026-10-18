import XCTest
import RagaCore
import Tala

/// Tala Studio (P4): the web tala page has NO test coverage, so
/// this suite is new (parity plan §6.3) — tala/jati math, Adi,
/// chapu, click tiers, tap tempo, settings validation with the
/// "adi" migration, the store round-trip and wheel geometry.
final class TalaTests: XCTestCase {

    func testGroupsAndTotals() {
        XCTAssertEqual(TalaSpec.talas.count, 7)
        XCTAssertEqual(TalaSpec.groups(talaId: "triputa", jatiId: "chatusra").map { $0.count },
                       [4, 2, 2])
        XCTAssertEqual(TalaSpec.totalBeats(talaId: "triputa", jatiId: "chatusra"), 8)
        XCTAssertEqual(TalaSpec.groups(talaId: "jhampa", jatiId: "khanda").map { $0.count },
                       [5, 1, 2])
        // The cycle range across every combination is 3…29.
        var totals: [Int] = []
        for tala in TalaSpec.talas {
            for jati in TalaSpec.jatis {
                totals.append(TalaSpec.totalBeats(talaId: tala.id, jatiId: jati.id))
            }
        }
        XCTAssertEqual(totals.min(), 3)
        XCTAssertEqual(totals.max(), 29)
    }

    func testChapuIgnoresJati() {
        XCTAssertEqual(TalaSpec.groups(talaId: "misraChapu", jatiId: "tisra").map { $0.count },
                       [7])
        XCTAssertEqual(TalaSpec.totalBeats(talaId: "khandaChapu", jatiId: "sankeerna"), 5)
        XCTAssertTrue(TalaSpec.isChapu("misraChapu"))
        XCTAssertFalse(TalaSpec.isChapu("triputa"))
    }

    func testNamesAndCycleLine() {
        XCTAssertTrue(TalaSpec.isAdi(talaId: "triputa", jatiId: "chatusra"))
        XCTAssertEqual(TalaSpec.comboName(talaId: "triputa", jatiId: "chatusra"), "Adi")
        XCTAssertEqual(TalaSpec.comboName(talaId: "triputa", jatiId: "tisra"), "Tisra Triputa")
        XCTAssertEqual(TalaSpec.comboName(talaId: "misraChapu", jatiId: "tisra"), "Misra Chapu")
        XCTAssertEqual(TalaSpec.cycleLine(talaId: "triputa", jatiId: "chatusra"),
                       "Chatusra Triputa · 4 + 2 + 2 · 8 aksharas / cycle")
        XCTAssertEqual(TalaSpec.cycleLine(talaId: "khandaChapu", jatiId: "tisra"),
                       "5 · 5 aksharas / cycle")
        XCTAssertEqual(TalaSpec.cycleLine(talaId: "matya", jatiId: "misra"),
                       "7 + 2 + 7 · 16 aksharas / cycle")
    }

    func testClickTiersAndSubDuration() {
        XCTAssertEqual(TalaSpec.click(beat: 0, sub: 0).frequency, 1320)
        XCTAssertEqual(TalaSpec.click(beat: 0, sub: 0).gain, 0.55)
        XCTAssertEqual(TalaSpec.click(beat: 3, sub: 0).frequency, 880)
        XCTAssertEqual(TalaSpec.click(beat: 3, sub: 0).gain, 0.45)
        XCTAssertEqual(TalaSpec.click(beat: 0, sub: 2).frequency, 660)
        XCTAssertEqual(TalaSpec.click(beat: 0, sub: 2).gain, 0.22)
        XCTAssertEqual(TalaSpec.subDuration(bpm: 60, nadai: 4), 0.25)
        XCTAssertEqual(TalaSpec.subDuration(bpm: 120, nadai: 1), 0.5)
    }

    func testTapTempo() {
        XCTAssertEqual(TalaSpec.tapTempo(stamps: [0, 0.5, 1.0]), 120)
        XCTAssertEqual(TalaSpec.tapTempo(stamps: [0, 1.0]), 60)
        XCTAssertNil(TalaSpec.tapTempo(stamps: [0]))
        // Stale taps fall out of the 2.5 s window.
        XCTAssertEqual(TalaSpec.tapTempo(stamps: [0, 10, 10.5, 11.0]), 120)
        XCTAssertNil(TalaSpec.tapTempo(stamps: [0, 3, 6]))
        // Clamped to the 30–120 range.
        XCTAssertEqual(TalaSpec.tapTempo(stamps: [0, 0.25]), 120)
        XCTAssertEqual(TalaSpec.tapTempo(stamps: [0, 2.4]), 30)
    }

    func testSettingsValidation() {
        let migrated = TalaSettings(storedTalaId: "adi", storedJatiId: nil,
                                    storedBPM: nil, storedNadai: nil)
        XCTAssertEqual(migrated.talaId, "triputa")
        XCTAssertEqual(migrated.jatiId, "chatusra")
        // A stored jati still applies after the migration (web order).
        let migratedJati = TalaSettings(storedTalaId: "adi", storedJatiId: "misra",
                                         storedBPM: nil, storedNadai: nil)
        XCTAssertEqual(migratedJati.jatiId, "misra")
        let bad = TalaSettings(storedTalaId: "nope", storedJatiId: "nope",
                               storedBPM: 200, storedNadai: 7)
        XCTAssertEqual(bad, TalaSettings())
        let chapu = TalaSettings(storedTalaId: "khandaChapu", storedJatiId: "khanda",
                                 storedBPM: 90, storedNadai: 2)
        XCTAssertEqual(chapu.talaId, "khandaChapu")
        XCTAssertEqual(chapu.bpm, 90)
        XCTAssertEqual(chapu.nadai, 2)
    }

    func testSettingsStoreRoundTrip() {
        let suite = UserDefaults(suiteName: "tala-tests-\(UUID().uuidString)")!
        let store = TalaSettingsStore(defaults: suite)
        XCTAssertEqual(store.load(), TalaSettings())
        store.save(TalaSettings(talaId: "ata", jatiId: "misra", bpm: 84, nadai: 3))
        XCTAssertEqual(store.load(),
                       TalaSettings(talaId: "ata", jatiId: "misra", bpm: 84, nadai: 3))
    }

    func testWheelGeometry() {
        let dots = TalaSpec.wheelDots(talaId: "triputa", jatiId: "chatusra")
        XCTAssertEqual(dots.count, 8)
        // Dots sit at the centre of their akshara slot (the web
        // formula), so the first dot is offset from the top by half
        // a laghu share: -90° + (0.5/4) of the 4/8 segment.
        XCTAssertEqual(dots[0].x, 179.45, accuracy: 0.6)
        XCTAssertEqual(dots[0].y, 39.46, accuracy: 0.6)
        XCTAssertTrue(dots[0].isSamam)
        XCTAssertTrue(dots.dropFirst().allSatisfy { !$0.isSamam })
        XCTAssertEqual(dots[0].radius, 11)
        // The widest cycle (Dhruva Sankeerna, 29) shrinks the dots.
        let wide = TalaSpec.wheelDots(talaId: "dhruva", jatiId: "sankeerna")
        XCTAssertEqual(wide.count, 29)
        XCTAssertEqual(wide[0].radius, 300.0 / 29.0, accuracy: 0.01)
        // Every dot lies on the circle.
        for dot in wide {
            let d = hypot(dot.x - 140, dot.y - 140)
            XCTAssertEqual(d, 108, accuracy: 0.6)
        }
    }
}
