import XCTest
@testable import JgDo

final class TipsStoreTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: TipsStore.tipsEnabledKey)
        UserDefaults.standard.removeObject(forKey: "dismissedTipIDs")
        super.tearDown()
    }

    func testTipsEnabledByDefault() {
        XCTAssertTrue(TipsStore.tipsEnabled)
    }

    func testShouldShowUndismissedTip() {
        XCTAssertTrue(TipsStore.shouldShow("some-new-tip"))
    }

    func testDismissedTipDoesNotShowAgain() {
        TipsStore.dismiss("clipboard-pin")
        XCTAssertFalse(TipsStore.shouldShow("clipboard-pin"))
    }

    func testDismissingOneTipDoesNotAffectAnother() {
        TipsStore.dismiss("clipboard-pin")
        XCTAssertTrue(TipsStore.shouldShow("another-tip"))
    }

    func testGlobalOptOutHidesEverything() {
        TipsStore.tipsEnabled = false
        XCTAssertFalse(TipsStore.shouldShow("clipboard-pin"))
        XCTAssertFalse(TipsStore.shouldShow("anything"))
    }
}
