import AppKit

/// "Focus Mode" — hides every regular app's windows except the frontmost
/// app's, then un-hides exactly those apps again on toggle-off. Built on
/// `NSRunningApplication.hide()/unhide()` (the same public mechanism as
/// ⌘H/Option-clicking the desktop) rather than per-window AX hiding — it's
/// simpler, more reliable across apps with unusual window setups, and
/// restoring is just "unhide the apps we hid," no per-window state to track.
@Observable
final class FocusModeService {
    static let shared = FocusModeService()
    private init() {}

    private(set) var isActive = false
    /// The apps THIS activation hid — restored on toggle-off. If the user
    /// manually un-hides one in between, `unhide()` on an already-visible
    /// app is a harmless no-op.
    private var hiddenPIDs: [pid_t] = []

    @discardableResult
    func toggle() -> Bool {
        isActive ? deactivate() : activate()
        return isActive
    }

    private func activate() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && $0.processIdentifier != front.processIdentifier
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && !$0.isHidden
        }
        hiddenPIDs = others.map(\.processIdentifier)
        for app in others { app.hide() }
        isActive = true
    }

    private func deactivate() {
        for pid in hiddenPIDs {
            NSRunningApplication(processIdentifier: pid)?.unhide()
        }
        hiddenPIDs = []
        isActive = false
    }
}
