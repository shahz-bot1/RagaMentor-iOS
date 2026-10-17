import XCTest
import LoopLab

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
