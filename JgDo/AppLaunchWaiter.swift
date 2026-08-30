import AppKit
import ApplicationServices

/// Launches an app by bundle ID if it's not already running, then polls
/// (not a blocking sleep) until it reports a window. Shared by
/// `WorkspaceCommandExecutor` (NL Workspace) and `WorkspaceTemplateService`
/// (preset templates) — both need "make sure this app is up and has a
/// window" before placing it.
@MainActor
enum AppLaunchWaiter {
    /// Already-running instance if there is one; otherwise launches it and
    /// waits up to ~5s for a window. Best-effort — a very slow app may
    /// still be missed.
    static func launchOrFind(bundleID: String) async -> NSRunningApplication? {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            return running
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())

        for _ in 0..<25 {   // 25 × 200ms ≈ 5s
            if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
               hasAnyWindow(running) {
                return running
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })
    }

    static func hasAnyWindow(_ app: NSRunningApplication) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return false }
        return !windows.isEmpty
    }
}
