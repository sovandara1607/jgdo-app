import XCTest
@testable import JgDo

/// `PermissionMonitor` wraps two synchronous system calls behind a
/// start/stop-able poll loop — these tests cover the loop's lifecycle
/// (idempotent start/stop, `refresh()` reflecting live state) rather than
/// the underlying `AXIsProcessTrusted()`/`WindowThumbnailService` values
/// themselves, which depend on the host machine's actual permission grants.
@MainActor
final class PermissionMonitorTests: XCTestCase {

    override func tearDown() {
        PermissionMonitor.shared.stop()
        super.tearDown()
    }

    func testRefreshReflectsLiveAccessibilityState() {
        PermissionMonitor.shared.refresh()
        XCTAssertEqual(PermissionMonitor.shared.accessibilityTrusted, AXIsProcessTrusted())
    }

    func testRefreshReflectsLiveScreenRecordingState() {
        PermissionMonitor.shared.refresh()
        XCTAssertEqual(PermissionMonitor.shared.screenRecordingAuthorized, WindowThumbnailService.isAuthorized)
    }

    func testStartIsIdempotent() {
        // Calling start() twice must not create a second timer (no crash,
        // no leaked Timer — hard to assert directly, but at minimum the
        // second call must return promptly rather than resetting state).
        PermissionMonitor.shared.start()
        PermissionMonitor.shared.start()
        PermissionMonitor.shared.stop()
    }

    func testStopBeforeStartIsSafeNoOp() {
        PermissionMonitor.shared.stop()
    }
}
