import XCTest
@testable import JgDo

/// CGEvent tap creation itself needs Accessibility permission (unavailable
/// headlessly in CI), so these stay at the state-machine level: the
/// `static weak var live` reference each controller's `@convention(c)`
/// callback reads, and idempotency of start()/stop(). Real tap
/// enable/disable/run-loop-source cleanup is covered by code review (see
/// the plan) rather than here, since it can't be observed without a live tap.
final class EventTapLifecycleTests: XCTestCase {

    // MARK: HotkeyManager

    func testHotkeyManagerStartSetsLiveAndStopClearsIt() {
        let manager = HotkeyManager()
        XCTAssertNil(HotkeyManager.live)

        manager.start()
        XCTAssertTrue(HotkeyManager.live === manager)

        manager.stop()
        XCTAssertNil(HotkeyManager.live)
    }

    func testHotkeyManagerStopBeforeStartIsSafeNoOp() {
        let manager = HotkeyManager()
        manager.stop() // must not crash even though start() was never called
        XCTAssertNil(HotkeyManager.live)
    }

    func testHotkeyManagerDoubleStartDoesNotReassignLive() {
        let manager = HotkeyManager()
        manager.start()
        // A second start() while already live must be a no-op rather than
        // tearing down and recreating the tap — that used to leak a mach
        // port + run-loop source pair per extra call.
        manager.start()
        XCTAssertTrue(HotkeyManager.live === manager)
        manager.stop()
        XCTAssertNil(HotkeyManager.live)
    }

    // MARK: WindowDragController

    func testWindowDragControllerStartSetsLiveAndStopClearsIt() {
        let controller = WindowDragController()
        XCTAssertNil(WindowDragController.live)

        controller.start()
        XCTAssertTrue(WindowDragController.live === controller)

        controller.stop()
        XCTAssertNil(WindowDragController.live)
    }

    func testWindowDragControllerDoubleStartDoesNotReassignLive() {
        let controller = WindowDragController()
        controller.start()
        controller.start()
        XCTAssertTrue(WindowDragController.live === controller)
        controller.stop()
        XCTAssertNil(WindowDragController.live)
    }

    // MARK: CleaningModeController

    @MainActor
    func testCleaningModeStopWithoutStartIsSafeNoOp() {
        let controller = CleaningModeController.shared
        controller.stop() // must not crash regardless of prior state
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(CleaningModeController.live)
    }

    @MainActor
    func testCleaningModeStartWithoutAccessibilityDoesNotClaimActive() throws {
        // CI has no Accessibility grant for the test host, so start() must
        // hit the permission-check guard and leave state untouched rather
        // than reporting "Keyboard Locked" without an actual working tap.
        guard !AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility is trusted in this environment; the no-permission path can't be exercised.")
        }
        let controller = CleaningModeController.shared
        controller.start()
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(CleaningModeController.live)
    }
}
