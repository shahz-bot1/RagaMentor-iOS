import XCTest
import AudioKit

/// Cross-studio audio focus (P6 hardening): registration,
/// stop-all, the sparing token, and unregistration.
final class StudioAudioFocusTests: XCTestCase {

    func testStopAllStopsEveryRegistration() {
        let focus = StudioAudioFocus()
        var stopped: [String] = []
        focus.register { stopped.append("a") }
        focus.register { stopped.append("b") }
        XCTAssertEqual(focus.registeredCount, 2)
        focus.stopAll()
        XCTAssertEqual(Set(stopped), ["a", "b"])
    }

    func testStopAllSparesTheStarter() {
        let focus = StudioAudioFocus()
        var stopped: [String] = []
        let mine = focus.register { stopped.append("mine") }
        focus.register { stopped.append("other") }
        focus.stopAll(except: mine)
        XCTAssertEqual(stopped, ["other"])
    }

    func testUnregisterRemovesTheStop() {
        let focus = StudioAudioFocus()
        var stopped = 0
        let token = focus.register { stopped += 1 }
        focus.unregister(token)
        XCTAssertEqual(focus.registeredCount, 0)
        focus.stopAll()
        XCTAssertEqual(stopped, 0)
    }
}
