import XCTest
import SwiftData
@testable import JgDo

/// Covers the pieces of the workspace-restoration rewrite that don't need
/// a live AX connection or real running apps: `RestoreDiagnostics`'
/// summarization (the user-facing payoff of no longer silently dropping
/// restore failures), the `Workspace`/`WorkspaceWindow` model fields B3
/// added (`restoreOnLaunch`, `displayUUID`), and — via
/// `WorkspaceService`'s injected `PersistenceProviding` — a real
/// integration test of save/reload/rename/delete/restore-on-launch against
/// an isolated in-memory store. The AX-window-matching and adaptive-poll
/// logic inside `restore(_:)`/`place(...)` itself still needs a live
/// Accessibility connection to real app windows, so THAT part isn't
/// covered by automated tests here.
@MainActor
final class WorkspaceRestorationTests: XCTestCase {

    // MARK: - RestoreDiagnostics

    func testAllAppsFullyPlacedHasNoIssues() {
        let d = RestoreDiagnostics()
        d.record(.placed(app: "Mail", matched: 2, total: 2))
        d.record(.placed(app: "Safari", matched: 1, total: 1))
        XCTAssertFalse(d.hasIssues)
        XCTAssertEqual(d.summary, "2 of 2 apps fully restored")
    }

    func testMissingAppIsReportedAsAnIssue() {
        let d = RestoreDiagnostics()
        d.record(.placed(app: "Mail", matched: 2, total: 2))
        d.record(.appNotInstalled(app: "Slack"))
        XCTAssertTrue(d.hasIssues)
        XCTAssertTrue(d.summary.contains("1 of 2"))
        XCTAssertTrue(d.summary.contains("Slack not installed"))
    }

    func testPartialWindowMatchIsReportedAsAnIssue() {
        let d = RestoreDiagnostics()
        // 3 windows saved, only 1 live window found — a real scenario if
        // the user only reopened one of several tabs/windows.
        d.record(.placed(app: "Finder", matched: 1, total: 3))
        XCTAssertTrue(d.hasIssues)
        XCTAssertTrue(d.summary.contains("Finder: 1 of 3 windows"))
        // A partial match still counts toward "fully restored" as 0, not 1.
        XCTAssertTrue(d.summary.hasPrefix("0 of 1"))
    }

    func testAppProducingNoWindowsIsReportedAsAnIssue() {
        let d = RestoreDiagnostics()
        d.record(.appProducedNoWindows(app: "Notes"))
        XCTAssertTrue(d.hasIssues)
        XCTAssertTrue(d.summary.contains("Notes opened no windows"))
    }

    func testEmptyDiagnosticsHasNoIssues() {
        let d = RestoreDiagnostics()
        XCTAssertFalse(d.hasIssues)
        XCTAssertEqual(d.summary, "0 of 0 apps fully restored")
    }

    // MARK: - Model fields

    func testWorkspaceRestoreOnLaunchDefaultsToFalse() {
        let workspace = Workspace(name: "Test")
        XCTAssertFalse(workspace.restoreOnLaunch, "restoring unprompted at every launch must be opt-in")
    }

    func testWorkspaceWindowDisplayUUIDRoundTrips() {
        let window = WorkspaceWindow(bundleID: "com.example.App", appName: "App", title: "Window",
                                      frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                      displayUUID: "ABCD-1234")
        XCTAssertEqual(window.displayUUID, "ABCD-1234")
    }

    func testWorkspaceWindowDisplayUUIDDefaultsToNilForOlderCallSites() {
        // The pre-B3 initializer shape (no displayUUID argument) must still
        // compile and produce nil, not crash or require a migration for
        // every existing call site.
        let window = WorkspaceWindow(bundleID: "com.example.App", appName: "App", title: nil,
                                      frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertNil(window.displayUUID)
    }

    // MARK: - displayUUID stability

    func testDisplayUUIDForSameScreenIsStableAcrossCalls() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("no screen available in this environment")
        }
        let first = WorkspaceService.displayUUID(for: screen)
        let second = WorkspaceService.displayUUID(for: screen)
        XCTAssertEqual(first, second)
    }

    // MARK: - Integration: WorkspaceService against an isolated store
    //
    // Exercises the real save/reload/rename/delete/restore-on-launch path
    // through actual SwiftData inserts and fetches — just against
    // `InMemoryPersistence` instead of `Persistence.shared`, so it can't
    // touch (or depend on) the developer's real workspace history. Window
    // placement itself (`saveCurrentLayout`'s AX/CGWindowList calls) isn't
    // exercised here — the graph below is built directly, standing in for
    // what a real capture would have produced.

    private func makeWorkspaceWithOneWindow(persistence: InMemoryPersistence, name: String) -> Workspace {
        let workspace = Workspace(name: name)
        let window = WorkspaceWindow(bundleID: "com.example.TestApp", appName: "TestApp", title: "Main Window",
                                     frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                     displayUUID: "TEST-DISPLAY-UUID")
        window.workspace = workspace
        workspace.windows.append(window)
        persistence.context.insert(workspace)
        persistence.save()
        return workspace
    }

    func testSavedWorkspaceReloadsWithItsWindows() {
        let persistence = InMemoryPersistence()
        let service = WorkspaceService(persistence: persistence)
        XCTAssertTrue(service.workspaces.isEmpty)

        let workspace = makeWorkspaceWithOneWindow(persistence: persistence, name: "Coding")
        service.reload()

        XCTAssertEqual(service.workspaces.count, 1)
        XCTAssertEqual(service.workspaces.first?.name, "Coding")
        XCTAssertEqual(service.workspaces.first?.windows.count, 1)
        XCTAssertEqual(service.workspaces.first?.windows.first?.bundleID, "com.example.TestApp")
        XCTAssertEqual(service.workspaces.first?.windows.first?.displayUUID, "TEST-DISPLAY-UUID")
        _ = workspace
    }

    func testRenameWorkspacePersistsAcrossReload() {
        let persistence = InMemoryPersistence()
        let service = WorkspaceService(persistence: persistence)
        let workspace = makeWorkspaceWithOneWindow(persistence: persistence, name: "Original")
        service.reload()

        service.rename(workspace, to: "Renamed")

        XCTAssertEqual(service.workspaces.first?.name, "Renamed")
    }

    func testSetRestoreOnLaunchPersistsAcrossReload() {
        let persistence = InMemoryPersistence()
        let service = WorkspaceService(persistence: persistence)
        let workspace = makeWorkspaceWithOneWindow(persistence: persistence, name: "Coding")
        service.reload()
        XCTAssertFalse(service.workspaces.first!.restoreOnLaunch)

        service.setRestoreOnLaunch(true, for: workspace)

        XCTAssertTrue(service.workspaces.first!.restoreOnLaunch)

        // A second, independent WorkspaceService instance against the SAME
        // store sees the change too — proves it's really persisted, not
        // just held in the first instance's in-memory `workspaces` array.
        let secondService = WorkspaceService(persistence: persistence)
        XCTAssertTrue(secondService.workspaces.first!.restoreOnLaunch)
    }

    func testDeleteWorkspaceCascadesToItsWindows() {
        let persistence = InMemoryPersistence()
        let service = WorkspaceService(persistence: persistence)
        let workspace = makeWorkspaceWithOneWindow(persistence: persistence, name: "Coding")
        service.reload()
        XCTAssertEqual(try? persistence.context.fetchCount(FetchDescriptor<WorkspaceWindow>()), 1)

        service.delete(workspace)

        XCTAssertTrue(service.workspaces.isEmpty)
        // The cascade delete rule on Workspace.windows must remove the
        // child WorkspaceWindow row too, not leave it orphaned.
        XCTAssertEqual(try? persistence.context.fetchCount(FetchDescriptor<WorkspaceWindow>()), 0)
    }

    func testRestoreWorkspacesFlaggedForLaunchOnlyRestoresFlaggedOnes() {
        let persistence = InMemoryPersistence()
        let service = WorkspaceService(persistence: persistence)
        let flagged = makeWorkspaceWithOneWindow(persistence: persistence, name: "AutoRestore")
        let unflagged = makeWorkspaceWithOneWindow(persistence: persistence, name: "Manual")
        service.reload()
        service.setRestoreOnLaunch(true, for: flagged)
        service.setRestoreOnLaunch(false, for: unflagged)

        // `restore(_:)` itself launches/places real apps via NSWorkspace —
        // out of scope for an isolated test — but the *selection* of which
        // workspaces qualify is pure, deterministic logic worth pinning:
        let toRestore = service.workspaces.filter(\.restoreOnLaunch)
        XCTAssertEqual(toRestore.map(\.name), ["AutoRestore"])
    }
}
