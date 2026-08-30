import XCTest
@testable import JgDo

final class RecentCommandsStoreTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "recentPaletteCommands")
        super.tearDown()
    }

    func testEmptyByDefault() {
        XCTAssertTrue(RecentCommandsStore.recent.isEmpty)
    }

    func testRecordAddsMostRecentFirst() {
        RecentCommandsStore.record(bundleID: "com.apple.Safari", layout: .leftHalf)
        RecentCommandsStore.record(bundleID: "com.apple.Terminal", layout: .rightHalf)
        let recent = RecentCommandsStore.recent
        XCTAssertEqual(recent.first?.bundleID, "com.apple.Terminal")
        XCTAssertEqual(recent.count, 2)
    }

    func testRecordingTheSamePairAgainMovesItToFrontWithoutDuplicating() {
        RecentCommandsStore.record(bundleID: "com.apple.Safari", layout: .leftHalf)
        RecentCommandsStore.record(bundleID: "com.apple.Terminal", layout: .rightHalf)
        RecentCommandsStore.record(bundleID: "com.apple.Safari", layout: .leftHalf)
        let recent = RecentCommandsStore.recent
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent.first?.bundleID, "com.apple.Safari")
    }

    func testCapsAtFiveEntries() {
        for i in 0..<8 {
            RecentCommandsStore.record(bundleID: "app\(i)", layout: .leftHalf)
        }
        XCTAssertEqual(RecentCommandsStore.recent.count, 5)
        XCTAssertEqual(RecentCommandsStore.recent.first?.bundleID, "app7")
    }
}
