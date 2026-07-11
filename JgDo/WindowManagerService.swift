import AppKit
import CoreGraphics
import ApplicationServices

private let skippedApps: Set<String> = [
    "Dock", "Window Server", "JgDo",
    "Notification Center", "Control Center", "SystemUIServer"
]

final class WindowManagerService {

    // MARK: Fetch

    func fetchWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let runningApps = NSWorkspace.shared.runningApplications
        var result: [WindowInfo] = []

        for dict in list {
            guard
                let windowID = dict[kCGWindowNumber as String] as? CGWindowID,
                let pid      = dict[kCGWindowOwnerPID as String] as? pid_t,
                let appName  = dict[kCGWindowOwnerName as String] as? String,
                let layer    = dict[kCGWindowLayer as String] as? Int,
                layer == 0,
                !skippedApps.contains(appName)
            else { continue }

            let title = dict[kCGWindowName as String] as? String ?? ""
            var bounds = CGRect.zero
            if let bd = dict[kCGWindowBounds as String] as? [String: CGFloat],
               let x = bd["X"], let y = bd["Y"], let w = bd["Width"], let h = bd["Height"] {
                bounds = CGRect(x: x, y: y, width: w, height: h)
            }
            guard bounds.width >= 100 && bounds.height >= 50 else { continue }

            let icon = runningApps.first(where: { $0.processIdentifier == pid })?.icon
            result.append(WindowInfo(
                windowID: windowID,
                appName: appName,
                windowTitle: title.isEmpty ? appName : title,
                pid: pid,
                icon: icon,
                bounds: bounds
            ))
        }
        return result
    }

    struct WindowBounds {
        let windowID: CGWindowID
        let pid: pid_t
        let appName: String
        let title: String
        let bounds: CGRect
    }

    /// Same window set as `fetchWindows()`, but skips the icon lookup (which
    /// linear-scans `NSWorkspace.runningApplications` per window) — for
    /// high-frequency polling paths like live ⌘-drag tracking, where only
    /// geometry is needed and the icon cost isn't worth paying every tick.
    func fetchWindowBounds() -> [WindowBounds] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [WindowBounds] = []
        for dict in list {
            guard
                let windowID = dict[kCGWindowNumber as String] as? CGWindowID,
                let pid      = dict[kCGWindowOwnerPID as String] as? pid_t,
                let appName  = dict[kCGWindowOwnerName as String] as? String,
                let layer    = dict[kCGWindowLayer as String] as? Int,
                layer == 0,
                !skippedApps.contains(appName)
            else { continue }

            var bounds = CGRect.zero
            if let bd = dict[kCGWindowBounds as String] as? [String: CGFloat],
               let x = bd["X"], let y = bd["Y"], let w = bd["Width"], let h = bd["Height"] {
                bounds = CGRect(x: x, y: y, width: w, height: h)
            }
            guard bounds.width >= 100 && bounds.height >= 50 else { continue }
            let title = dict[kCGWindowName as String] as? String ?? ""
            result.append(WindowBounds(windowID: windowID, pid: pid, appName: appName,
                                        title: title.isEmpty ? appName : title, bounds: bounds))
        }
        return result
    }

    // MARK: Focus

    func focusWindow(_ window: WindowInfo) {
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        guard let axWin = findAXWindow(for: window) else { return }
        AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
    }

    // MARK: Window actions

    func minimizeWindow(_ window: WindowInfo) {
        guard let axWin = findAXWindow(for: window) else { return }
        AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, true as CFTypeRef)
    }

    func closeWindow(_ window: WindowInfo) {
        guard let axWin = findAXWindow(for: window) else { return }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWin, kAXCloseButtonAttribute as CFString, &ref) == .success,
              let btn = ref else { return }
        AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
    }

    func hideApp(_ window: WindowInfo) {
        NSRunningApplication(processIdentifier: window.pid)?.hide()
    }

    // MARK: Permissions

    var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    func requestAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    // MARK: Layout support

    /// Moves and resizes an AX window. `frame` is in AppKit coords (bottom-left origin).
    func applyFrame(_ frame: CGRect, to window: WindowInfo, on screen: NSScreen) {
        guard let axWin = findAXWindow(for: window) else { return }
        let mainH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        var origin = CGPoint(x: frame.minX, y: mainH - frame.maxY)
        var size   = CGSize(width: frame.width, height: frame.height)
        if let pv = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, pv)
        }
        if let sv = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sv)
        }
        AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: window.pid)?.activate()
    }

    // MARK: Helpers

    /// Public wrapper so callers outside this file (WindowDragController's
    /// adjacent-resize path) can resolve a fetched WindowInfo to its live
    /// AXUIElement without duplicating the pid/title lookup below.
    func axWindow(for window: WindowInfo) -> AXUIElement? {
        findAXWindow(for: window)
    }

    private func findAXWindow(for window: WindowInfo) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(window.pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let axWindows = ref as? [AXUIElement] else { return nil }

        return axWindows.first { axWin in
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef)
            return (titleRef as? String) == window.windowTitle
        } ?? axWindows.first
    }
}

// MARK: - Shared AX geometry helpers
//
// Used both by WindowResizeService (hotkey/preset snapping) and
// WindowDragController (⌘-drag snap + adjacent resize) so the raw AX
// position/size plumbing lives in exactly one place.
extension WindowManagerService {

    /// Hit-tests the system-wide AX element at a global CG point (top-left
    /// origin) and resolves it to its owning window + owning pid. Walks
    /// `kAXParentAttribute` up from the hit element if it doesn't expose
    /// `kAXWindowAttribute` directly.
    static func hitTestWindow(at point: CGPoint) -> (window: AXUIElement, pid: pid_t)? {
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementRef) == .success,
              var element = elementRef else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
           let win = windowRef {
            return (win as! AXUIElement, pid)
        }

        var depth = 0
        while depth < 32 {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == kAXWindowRole {
                return (element, pid)
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else { return nil }
            element = parent as! AXUIElement
            depth += 1
        }
        return nil
    }

    /// Reads an AX window's current frame in CG global coordinates
    /// (top-left origin) — the same space AX position/size attributes,
    /// `CGWindowListCopyWindowInfo` bounds, and `CGEvent.location` all use.
    static func axFrame(of axWindow: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// Sets an AX window's frame (CG global coords) and reads back what was
    /// actually applied. Some apps clamp size to their own minimum; the
    /// read-back is the only way to discover that after the fact.
    @discardableResult
    static func setAXFrame(_ frame: CGRect, of axWindow: AXUIElement) -> CGRect {
        var origin = frame.origin
        var size = frame.size
        if let pv = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, pv)
        }
        if let sv = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sv)
        }
        return axFrame(of: axWindow) ?? frame
    }
}
