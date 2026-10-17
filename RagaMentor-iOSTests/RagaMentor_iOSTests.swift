import XCTest
@testable import RagaMentor_iOS

final class RagaMentor_iOSTests: XCTestCase {
    func testGreetingMessage() {
        XCTAssertEqual(Greeting.message, "Hello, RagaMentor!")
    }
}
