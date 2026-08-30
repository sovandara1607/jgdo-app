import XCTest
@testable import JgDo

/// `LicenseFeatureCoordinator` is the single start/stop choke point for
/// every subsystem that only makes sense while licensed. These tests stay
/// at the state-machine level (no real CGEvent tap / Accessibility
/// permission in CI, same constraint as `EventTapLifecycleTests`) and
/// assert the lifecycle contract: start() is idempotent, stop() actually
/// tears down what start() built, and stop() is safe to call repeatedly
/// or before any start().
@MainActor
final class LicenseLifecycleTests: XCTestCase {

    override func tearDown() {
        // Never leave the shared coordinator running into the next test —
        // it's a singleton, so state would otherwise leak across tests.
        LicenseFeatureCoordinator.shared.stop()
        super.tearDown()
    }

    func testStartCreatesHotkeyManagerAndDragControllerAndReportsRunning() {
        let coordinator = LicenseFeatureCoordinator.shared
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertNil(coordinator.hotkeyManager)
        XCTAssertNil(coordinator.dragController)

        var configuredManager: HotkeyManager?
        coordinator.start { mgr in configuredManager = mgr }

        XCTAssertTrue(coordinator.isRunning)
        XCTAssertNotNil(coordinator.hotkeyManager)
        XCTAssertNotNil(coordinator.dragController)
        // The closure passed to start() must receive the SAME instance the
        // coordinator ends up holding, not some throwaway copy.
        XCTAssertTrue(configuredManager === coordinator.hotkeyManager)
        // start() delegates to HotkeyManager.start()/WindowDragController.start(),
        // which register the static `live` refs exercised in EventTapLifecycleTests.
        XCTAssertTrue(HotkeyManager.live === coordinator.hotkeyManager)
        XCTAssertTrue(WindowDragController.live === coordinator.dragController)
    }

    func testStopTearsDownEverythingStartCreated() {
        let coordinator = LicenseFeatureCoordinator.shared
        coordinator.start { _ in }
        XCTAssertTrue(coordinator.isRunning)

        coordinator.stop()

        XCTAssertFalse(coordinator.isRunning)
        XCTAssertNil(coordinator.hotkeyManager)
        XCTAssertNil(coordinator.dragController)
        // Deactivation must be IMMEDIATE, not "until next launch" — the
        // static `live` refs the CGEvent tap callbacks read must be nil
        // the instant stop() returns.
        XCTAssertNil(HotkeyManager.live)
        XCTAssertNil(WindowDragController.live)
    }

    func testStartIsIdempotent() {
        let coordinator = LicenseFeatureCoordinator.shared
        coordinator.start { _ in }
        let firstManager = coordinator.hotkeyManager
        let firstDrag = coordinator.dragController

        // A second start() while already running must not rebuild
        // (and thereby leak) the managers.
        coordinator.start { _ in }
        XCTAssertTrue(coordinator.hotkeyManager === firstManager)
        XCTAssertTrue(coordinator.dragController === firstDrag)
    }

    func testStopBeforeStartIsSafeNoOp() {
        let coordinator = LicenseFeatureCoordinator.shared
        coordinator.stop() // must not crash even though start() was never called
        XCTAssertFalse(coordinator.isRunning)
    }

    func testStopIsIdempotent() {
        let coordinator = LicenseFeatureCoordinator.shared
        coordinator.start { _ in }
        coordinator.stop()
        coordinator.stop() // second call must be a safe no-op
        XCTAssertFalse(coordinator.isRunning)
    }

    /// End-to-end through the public surface a user actually triggers:
    /// activating a (test-signed) license starts nothing on its own — only
    /// `AppDelegate` wires that — but `deactivate()` must immediately stop
    /// the coordinator if it happens to be running, closing the gap where
    /// deactivation used to leave every licensed subsystem running.
    func testLicenseManagerDeactivateStopsCoordinator() {
        let coordinator = LicenseFeatureCoordinator.shared
        coordinator.start { _ in }
        XCTAssertTrue(coordinator.isRunning)

        LicenseManager.shared.deactivate()

        XCTAssertFalse(coordinator.isRunning)
        XCTAssertNil(HotkeyManager.live)
        XCTAssertNil(WindowDragController.live)
    }
}
