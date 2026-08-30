import AppKit
import ApplicationServices
import SwiftData

/// "Park Window" — different from a plain minimize: parking captures the
/// window's full pre-park context (frame, display, app identity) into its
/// OWN persisted, searchable, named list, independent of the Dock. The
/// actual removal-from-workspace mechanism IS AX minimize (there's no
/// other way to pull a live window out of the visible workspace without
/// closing it), but restore uses JgDo's own captured frame rather than
/// relying solely on the OS's minimize/unminimize memory — so a parked
/// window comes back to the right place even if the OS's own state gets
/// confused by a monitor reconnect in between.
@Observable
final class WindowParkingService {
    static let shared = WindowParkingService()

    private(set) var parkedWindows: [ParkedWindow] = []
    private let windowService = WindowManagerService()

    private init() { reload() }

    func reload() {
        let ctx = Persistence.shared.context
        parkedWindows = ctx.fetchLogged(FetchDescriptor<ParkedWindow>(
            sortBy: [SortDescriptor(\.parkedAt, order: .reverse)]), using: AppLog.workspace)
    }

    /// Parks the focused window of `app`. Returns the window's title on
    /// success, for a caller that wants to flash a confirmation.
    @discardableResult
    func park(_ app: NSRunningApplication) -> String? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        let axWindow = ref as! AXUIElement
        return park(axWindow: axWindow, app: app)
    }

    /// Parks a specific already-resolved window (used for "Park entire
    /// Snap Group").
    @discardableResult
    func park(_ window: WindowInfo) -> String? {
        guard let axWindow = windowService.axWindow(for: window),
              let app = NSRunningApplication(processIdentifier: window.pid) else { return nil }
        return park(axWindow: axWindow, app: app)
    }

    private func park(axWindow: AXUIElement, app: NSRunningApplication) -> String? {
        guard let cgFrame = WindowManagerService.axFrame(of: axWindow) else { return nil }
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String).flatMap { $0.isEmpty ? nil : $0 } ?? app.localizedName ?? "Window"

        let appKit = CoordinateSpace.appKit(fromCG: cgFrame)
        let screenName = WindowManagerService.screenLabel(forCGBounds: cgFrame)

        let entry = ParkedWindow(bundleID: app.bundleIdentifier ?? app.localizedName ?? "",
                                  appName: app.localizedName ?? "Unknown",
                                  title: title, frame: appKit, screenName: screenName)
        Persistence.shared.context.insert(entry)
        Persistence.shared.save()
        reload()

        AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, true as CFTypeRef)
        return title
    }

    /// Restores a parked window: un-minimizes it and re-applies the
    /// captured frame (falling back to a centered default on the main
    /// screen if the original display is gone — "best available fallback
    /// location," per spec). No-ops gracefully if the owning app isn't
    /// running (it quit while parked) — the entry is left for the user to
    /// manually delete rather than silently vanishing.
    func restore(_ parked: ParkedWindow) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == parked.bundleID }) else {
            return
        }
        windowService.unminimizeWindow(bundlePID: app.processIdentifier, title: parked.title)

        let targetScreen = NSScreen.screens.first { $0.localizedName == parked.screenName } ?? NSScreen.main
        var frame = parked.frame
        if let targetScreen, parked.screenName != nil, NSScreen.screens.first(where: { $0.localizedName == parked.screenName }) == nil {
            // Original display is gone — center a same-size frame on the
            // fallback screen instead of restoring an off-screen position.
            let vf = targetScreen.visibleFrame
            frame = CGRect(x: vf.midX - frame.width / 2, y: vf.midY - frame.height / 2,
                            width: min(frame.width, vf.width), height: min(frame.height, vf.height))
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let axWindows = ref as? [AXUIElement] else { return }
        let axWindow = axWindows.first { win in
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            return (titleRef as? String) == parked.title
        } ?? axWindows.first
        guard let axWindow else { return }

        let cgFrame = CoordinateSpace.cg(fromAppKit: frame)
        WindowManagerService.setAXFrame(cgFrame, of: axWindow)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        app.activate()

        delete(parked)
    }

    func restoreAll() {
        for parked in parkedWindows { restore(parked) }
    }

    func delete(_ parked: ParkedWindow) {
        Persistence.shared.context.delete(parked)
        Persistence.shared.save()
        reload()
    }
}
