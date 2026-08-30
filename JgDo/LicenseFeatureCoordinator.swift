import AppKit

/// Owns start/stop for every JgDo subsystem that has a real system-level
/// footprint while licensed: global hotkeys, ⌘-drag snapping, clipboard
/// polling, battery monitoring, and keyboard-cleaning mode. Replaces the
/// old one-way `AppDelegate.startLicensedFeatures()`, which had no
/// `stop()` counterpart at all — `LicenseManager.deactivate()` used to only
/// clear the stored key, leaving every one of these running exactly as
/// before until the app was quit and relaunched.
///
/// Deliberately does NOT take over panel construction (the HUD, clipboard
/// history, command palette, etc. panels stay AppDelegate-owned NSPanels —
/// see `AppDelegate.startLicensedFeatures()`) or passive/observational
/// services with no privileged system hook (`WindowMemoryService`,
/// `WorkflowInsightsService`, `SystemStatusService`) — those cause no harm
/// idle and stopping them adds no security value. The subsystems here are
/// specifically the ones that keep working (intercepting keystrokes,
/// recording the clipboard, holding a global event tap) even with no
/// JgDo window open, which is exactly what "deactivation must immediately
/// stop X" is about.
@MainActor
@Observable
final class LicenseFeatureCoordinator {
    static let shared = LicenseFeatureCoordinator()

    private(set) var hotkeyManager: HotkeyManager?
    private(set) var dragController: WindowDragController?
    private(set) var isRunning = false

    private init() {}

    /// Starts every licensed subsystem. `configureHotkeys` lets the caller
    /// (AppDelegate) wire its own callback closures onto a freshly built
    /// `HotkeyManager` without owning that manager's lifecycle itself —
    /// construction, start, and stop all happen here so there's exactly one
    /// place that can leave a tap running with nothing tracking it.
    /// Idempotent: a second `start()` while already running is a no-op,
    /// same reasoning as `HotkeyManager.start()`'s own guard.
    func start(configureHotkeys: (HotkeyManager) -> Void) {
        guard !isRunning else { return }
        isRunning = true

        let manager = HotkeyManager()
        configureHotkeys(manager)
        manager.start()
        hotkeyManager = manager

        let drag = WindowDragController()
        drag.start()
        dragController = drag

        ClipboardService.shared.start()
        if AppSettings.lowBatteryAlertsEnabled {
            BatteryAlertService.shared.start()
        }
    }

    /// Symmetric stop, called from three places: `LicenseManager.deactivate()`
    /// (immediately, while the app keeps running), `AppDelegate.applicationWillTerminate`
    /// (quit), and available for tests. Safe to call when not running.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        hotkeyManager?.stop()
        hotkeyManager = nil
        dragController?.stop()
        dragController = nil

        ClipboardService.shared.stop()
        BatteryAlertService.shared.stop()
        // Reachable today only via the isPro-gated status popover, but
        // stopped unconditionally here too — cheap defense-in-depth against
        // a future call site that isn't gated the same way, and a no-op if
        // it isn't currently active.
        CleaningModeController.shared.stop()
    }
}
