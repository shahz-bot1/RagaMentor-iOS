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

extension RagaBrowserTests {
    /// The v14 piano geometry (P6 fix): keys resize to the
    /// container, Sa's left edge is at 0 and Sa′ ends at exactly
    /// 100, with the neighbours bleeding off both ends.
    func testPianoGeometrySaWhite() {
        // Sa = C: 8 white keys in rel 0…12, so ww = 12.5%.
        let keys = PianoGeometry.keys(saPitchClass: 0)
        let sa = keys.first { $0.rel == 0 }!
        XCTAssertEqual(sa.left, 0, accuracy: 0.001)
        XCTAssertEqual(sa.width, 12.5, accuracy: 0.001)
        let top = keys.first { $0.rel == 12 }!
        XCTAssertEqual(top.left + top.width, 100, accuracy: 0.001)
        // The rel −1 neighbour bleeds off the left edge.
        let below = keys.first { $0.rel == -1 }!
        XCTAssertLessThan(below.left, 0)
        // Black keys are 0.62× and centred on their boundary:
        // rel 1 sits between Sa (0–12.5) and rel 2 (12.5–25).
        let black = keys.first { $0.rel == 1 }!
        XCTAssertTrue(black.isBlack)
        XCTAssertEqual(black.width, 12.5 * 0.62, accuracy: 0.001)
        XCTAssertEqual(black.left + black.width / 2, 12.5, accuracy: 0.001)
    }

    func testPianoGeometrySaBlack() {
        // Sa = C#: 7 white keys in rel 0…12, corrected denominator.
        let keys = PianoGeometry.keys(saPitchClass: 1)
        let sa = keys.first { $0.rel == 0 }!
        XCTAssertTrue(sa.isBlack)
        XCTAssertEqual(sa.left, 0, accuracy: 0.001)
        let ww = 100.0 / (7.0 + 0.62)
        XCTAssertEqual(sa.width, ww * 0.62, accuracy: 0.001)
        // The last white (rel 11) still ends inside the strip and
        // the top neighbour (rel 12, black) reaches ~100.
        let topBlack = keys.first { $0.rel == 12 }!
        XCTAssertEqual(topBlack.left + topBlack.width, 100, accuracy: 0.6)
    }
}

import SwiftUI
import UIKit
import AudioKit
import RagaBrowser
import PersistenceKit

/// Regression guard (v1.5.26): host the redesigned Raga Browser
/// (search pill + scrolling chip rail) at phone width and
/// assert no VISIBLE subview is wider than the screen — the
/// rail must scroll, never stretch the page (the FlowStack
/// lock-in class of bug).
@MainActor
final class RagaBrowserLayoutTests: XCTestCase {
    private final class FakeTone: ToneEngine {
        var samplesReady = true
        func prepare() async {}
        func playNote(semitone: Int, atOffset offset: Double, duration: Double) {}
        func stopAll() {}
    }

    func testBrowserHeaderFitsScreenWidth() {
        let host = UIHostingController(rootView:
            RagaBrowserView(library: DefaultRagaLibrary(),
                            sequencePlayer: SequencePlayer(tone: FakeTone())))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        window.layoutIfNeeded()
        // Measure in WINDOW coordinates and respect ancestor
        // clipping: a view wider than the screen only counts if
        // no ancestor clips it to the screen (a List's section
        // background bleeds 20 pt inside its own bounds, where
        // the List clips it — invisible, not a defect). The
        // rail's scroll content is exempt the same way.
        var frames: [(String, CGRect, Bool)] = []
        func walk(_ v: UIView, _ ancestorHidden: Bool, _ clipped: Bool) {
            let hidden = ancestorHidden || v.isHidden
            let rect = v.convert(v.bounds, to: window)
            let nowClipped = clipped
                || (v.clipsToBounds && rect.width <= 394 && rect.minX >= -1)
            if !clipped {
                frames.append((String(describing: type(of: v)), rect, hidden))
            }
            v.subviews.forEach { walk($0, hidden, nowClipped) }
        }
        walk(host.view, false, false)
        let over = frames.filter { $0.1.width > 394 && !$0.2 }
            .sorted { $0.1.width > $1.1.width }
        let dump = over.prefix(14)
            .map { "\($0.0) w=\(Int($0.1.width)) x=\(Int($0.1.minX))" }
            .joined(separator: " | ")
        XCTAssertTrue(over.isEmpty, "OVERWIDE(\(over.count)): \(dump)")
    }

    /// His spacing report (2026-10-21): the gap between the chip
    /// rail and the first list cell must be the standard header
    /// spacing (~10 pt), not the ~41 pt the list's own top
    /// content margin stacked on. Measured in window points.
    func testRailToFirstRowGapIsStandard() {
        let host = UIHostingController(rootView:
            RagaBrowserView(library: DefaultRagaLibrary(),
                            sequencePlayer: SequencePlayer(tone: FakeTone())))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        window.layoutIfNeeded()

        var railBottom: CGFloat?
        var firstCellTop: CGFloat?
        func walk(_ v: UIView) {
            let rect = v.convert(v.bounds, to: window)
            // The rail is the header's only short, wide scroll
            // view. Do NOT require content overflow: with three
            // short chips the content can fit its bounds exactly
            // (the first version of this finder missed it so).
            if let scroller = v as? UIScrollView,
               scroller.bounds.height < 80, scroller.bounds.width > 200 {
                railBottom = max(railBottom ?? 0, rect.maxY)
            }
            if String(describing: type(of: v)).contains("Cell"),
               rect.width > 200, rect.minY > 150 {
                firstCellTop = min(firstCellTop ?? .greatestFiniteMagnitude, rect.minY)
            }
            v.subviews.forEach(walk)
        }
        walk(host.view)
        guard let railBottom, let firstCellTop else {
            XCTFail("rail or first cell not found (rail=\(String(describing: railBottom)), cell=\(String(describing: firstCellTop)))")
            return
        }
        let gap = firstCellTop - railBottom
        XCTAssertTrue(gap >= 0 && gap <= 18,
                      "rail-to-cell gap is \(gap) pt — the standard is ~10")
    }
}
