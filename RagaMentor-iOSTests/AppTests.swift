import XCTest
@testable import RagaMentor_iOS

// App tests (PARITY-PLAN §6: the v0.6.0 suite, split per module in P0).
final class AppTests: XCTestCase {

    func testGreetingMessage() {
        XCTAssertEqual(Greeting.message, "Hello, RagaMentor!")
    }
}
