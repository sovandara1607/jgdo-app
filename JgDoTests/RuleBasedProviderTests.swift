import XCTest
@testable import JgDo

/// `RuleBasedProvider.parse` is pure text-in/`WorkspaceCommand`-out — no
/// AppKit, no live app list — so it's fully unit-testable with a fixture
/// list of "installed" app names, the same way `WindowMagnetismEngine`'s
/// pure geometry is.
final class RuleBasedProviderTests: XCTestCase {

    let apps = ["Slack", "Xcode", "Safari", "Terminal", "Notes", "Mail", "Calendar"]

    func testTwoAppsWithExplicitSides() {
        let cmd = RuleBasedProvider.parse("Put Slack on the left and Xcode on the right", installedAppNames: apps)
        XCTAssertEqual(cmd.placements.count, 2)
        XCTAssertTrue(cmd.placements.contains(.init(appName: "Slack", layout: .leftHalf)))
        XCTAssertTrue(cmd.placements.contains(.init(appName: "Xcode", layout: .rightHalf)))
        XCTAssertFalse(cmd.summary.isEmpty)
    }

    func testSplitScreenPhrasingWithNoPerAppKeyword() {
        let cmd = RuleBasedProvider.parse("Split screen with Terminal and Safari", installedAppNames: apps)
        XCTAssertEqual(cmd.placements.count, 2)
        XCTAssertEqual(cmd.placements.first?.appName, "Terminal")
        XCTAssertEqual(cmd.placements.first?.layout, .leftHalf)
        XCTAssertEqual(cmd.placements.last?.appName, "Safari")
        XCTAssertEqual(cmd.placements.last?.layout, .rightHalf)
    }

    func testSideBySidePhrasing() {
        let cmd = RuleBasedProvider.parse("Mail and Calendar side by side", installedAppNames: apps)
        XCTAssertEqual(cmd.placements.count, 2)
        XCTAssertEqual(cmd.placements.first?.appName, "Mail")
        XCTAssertEqual(cmd.placements.last?.appName, "Calendar")
    }

    func testMaximizeSingleApp() {
        let cmd = RuleBasedProvider.parse("Maximize Notes", installedAppNames: apps)
        XCTAssertEqual(cmd.placements, [.init(appName: "Notes", layout: .maximize)])
    }

    func testCenterSingleApp() {
        let cmd = RuleBasedProvider.parse("Center Notes please", installedAppNames: apps)
        XCTAssertEqual(cmd.placements, [.init(appName: "Notes", layout: .center)])
    }

    func testCornerPhraseBeatsBareKeyword() {
        // "top left" must win over the bare "left"/"top" keywords matching first.
        let cmd = RuleBasedProvider.parse("Put Slack in the top left corner", installedAppNames: apps)
        XCTAssertEqual(cmd.placements, [.init(appName: "Slack", layout: .topLeft)])
    }

    func testCloseInstructionIsSeparatedFromPlacements() {
        let cmd = RuleBasedProvider.parse("Close Slack and open Xcode on the right", installedAppNames: apps)
        XCTAssertEqual(cmd.appsToClose, ["Slack"])
        XCTAssertEqual(cmd.placements, [.init(appName: "Xcode", layout: .rightHalf)])
    }

    func testUnrecognizedTextProducesEmptyCommand() {
        let cmd = RuleBasedProvider.parse("do something completely unrelated", installedAppNames: apps)
        XCTAssertTrue(cmd.isEmpty)
    }

    func testAppNotInstalledIsNotMatched() {
        let cmd = RuleBasedProvider.parse("Put Photoshop on the left", installedAppNames: apps)
        XCTAssertTrue(cmd.placements.isEmpty)
    }

    func testCaseInsensitiveAppNameMatch() {
        let cmd = RuleBasedProvider.parse("put slack on the left", installedAppNames: apps)
        XCTAssertEqual(cmd.placements, [.init(appName: "Slack", layout: .leftHalf)])
    }
}
