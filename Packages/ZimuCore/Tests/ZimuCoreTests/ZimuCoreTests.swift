import XCTest
@testable import ZimuCore

final class ZimuCoreTests: XCTestCase {
    func testAppName() {
        XCTAssertEqual(ZimuCore.appName, "字幕AI")
    }
}
