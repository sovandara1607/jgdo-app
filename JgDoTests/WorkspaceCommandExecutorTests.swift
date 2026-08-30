import XCTest
@testable import JgDo

/// `WorkspaceCommandExecutor.validate` is pure data-in/data-out — no
/// AppKit, no AX, no live screens — the safety-critical step that keeps a
/// parsed command from acting on a hallucinated app or a disconnected
/// display. Fully unit-testable with fixture app-name lists and screen
/// counts.
final class WorkspaceCommandExecutorTests: XCTestCase {

    let apps = ["Slack", "Xcode", "Safari"]

    func testValidCommandPassesThroughWithNoIssues() {
        var cmd = WorkspaceCommand()
        cmd.placements = [.init(appName: "Slack", layout: .leftHalf)]
        let result = WorkspaceCommandExecutor.validate(cmd, installedAppNames: apps, screenCount: 1)
        XCTAssertEqual(result.placements, [.init(appName: "Slack", layout: .leftHalf, screenIndex: nil)])
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertTrue(result.isActionable)
    }

    func testFuzzyMatchesSlightlyMisspelledAppName() {
        var cmd = WorkspaceCommand()
        cmd.placements = [.init(appName: "slak", layout: .rightHalf)]
        let result = WorkspaceCommandExecutor.validate(cmd, installedAppNames: apps, screenCount: 1)
        XCTAssertEqual(result.placements.first?.appName, "Slack")
    }

    func testHallucinatedAppIsDroppedAndReportedAsAnIssue() {
        var cmd = WorkspaceCommand()
        cmd.placements = [.init(appName: "TotallyMadeUpApp9000", layout: .leftHalf)]
        let result = WorkspaceCommandExecutor.validate(cmd, installedAppNames: apps, screenCount: 1)
        XCTAssertTrue(result.placements.isEmpty)
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertFalse(result.isActionable)
    }

    func testInBoundsScreenIndexIsPreserved() {
        var cmd = WorkspaceCommand()
        cmd.placements = [.init(appName: "Xcode", layout: .maximize, screenIndex: 1)]
        let result = WorkspaceCommandExecutor.validate(cmd, installedAppNames: apps, screenCount: 2)
        XCTAssertEqual(result.placements.first?.screenIndex, 1)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testOutOfBoundsScreenIndexFallsBackToNilAndReportsIssue() {
        var cmd = WorkspaceCommand()
        cmd.placements = [.init(appName: "Xcode", layout: .maximize, screenIndex: 3)]
        let result = WorkspaceCommandExecutor.validate(cmd, installedAppNames: apps, screenCount: 1)
        XCTAssertEqual(result.placements.first?.screenIndex, nil)
        XCTAssertEqual(result.placements.first?.appName, "Xcode")
        XCTAssertFalse(result.issues.isEmpty)
    }

    func testNegativeScreenIndexIsRejected() {
        var cmd = WorkspaceCommand()
        cmd.placements = [.init(appName: "Xcode", layout: .maximize, screenIndex: -1)]
        let result = WorkspaceCommandExecutor.validate(cmd, installedAppNames: apps, screenCount: 2)
        XCTAssertNil(result.placements.first?.screenIndex)
    }

    func testCloseTargetsAreFuzzyMatchedTooAndUnmatchedOnesReported() {
        var cmd = WorkspaceCommand()
        cmd.appsToClose = ["Xcode", "NotAnApp"]
        let result = WorkspaceCommandExecutor.validate(cmd, installedAppNames: apps, screenCount: 1)
        XCTAssertEqual(result.appsToClose, ["Xcode"])
        XCTAssertEqual(result.issues.count, 1)
    }

    func testEmptyCommandIsNotActionable() {
        let result = WorkspaceCommandExecutor.validate(WorkspaceCommand(), installedAppNames: apps, screenCount: 1)
        XCTAssertFalse(result.isActionable)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testZeroReportedScreenCountDoesNotCrashAndStillAllowsIndexZero() {
        // screenCount: 0 is a defensive edge case (shouldn't happen in
        // practice — there's always at least one screen). `validate` treats
        // it the same as "1 screen" rather than rejecting index 0 outright,
        // since a real command is always typed on SOME screen.
        var cmd = WorkspaceCommand()
        cmd.placements = [.init(appName: "Slack", layout: .leftHalf, screenIndex: 0)]
        let result = WorkspaceCommandExecutor.validate(cmd, installedAppNames: apps, screenCount: 0)
        XCTAssertEqual(result.placements.first?.screenIndex, 0)
        XCTAssertTrue(result.issues.isEmpty)
    }
}
