import XCTest
@testable import JgDo

/// Smoke test validating the JgDoTests target itself is wired correctly
/// (host app builds, `@testable import` resolves, tests execute). Real
/// coverage lives in the other files in this target.
final class JgDoTests: XCTestCase {
    func testTargetIsWired() {
        XCTAssertTrue(true, "JgDoTests target executed successfully")
    }
}
