import AppKit
import ApplicationServices
import CoreGraphics

/// Private but long-stable AX symbol (used by every third-party macOS window
/// manager — Rectangle, yabai, Amethyst, …) that maps an AXUIElement window
/// to its CGWindowID. No public AX API exposes this. Safe to link directly
/// (not dlopen'd) since it lives in ApplicationServices, already linked for
/// every other AX call in this app.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: inout CGWindowID) -> AXError

/// "Always on Top" pinning for arbitrary windows. There's no public API to
/// raise one *specific other app's* window above all others persistently —
/// `CGSSetWindowLevel` (SkyLight, private) is the only way, so this is
/// loaded via dlopen the same way `MonitorControlService` loads
/// DisplayServices: the feature simply hides/no-ops if unavailable rather
/// than crashing on an OS where the symbol has moved or been removed.
@Observable
final class AlwaysOnTopService {
    static let shared = AlwaysOnTopService()

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SetLevelFn = @convention(c) (Int32, CGWindowID, Int32) -> Int32
    private let mainConnectionFn: MainConnectionFn?
    private let setLevelFn: SetLevelFn?

    /// Windows currently pinned floating, by CGWindowID. Intentionally not
    /// persisted — a pin is a live property of the running window, not
    /// durable user data; it naturally clears when the window closes.
    private(set) var pinnedWindowIDs: Set<CGWindowID> = []

    var isAvailable: Bool { mainConnectionFn != nil && setLevelFn != nil }

    private init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY
        )
        if let handle,
           let mainSym = dlsym(handle, "CGSMainConnectionID"),
           let setSym = dlsym(handle, "CGSSetWindowLevel") {
            mainConnectionFn = unsafeBitCast(mainSym, to: MainConnectionFn.self)
            setLevelFn = unsafeBitCast(setSym, to: SetLevelFn.self)
        } else {
            mainConnectionFn = nil
            setLevelFn = nil
        }
    }

    func isPinned(_ windowID: CGWindowID) -> Bool { pinnedWindowIDs.contains(windowID) }

    /// Toggles "always on top" for the focused window of `app`. Returns the
    /// window's current frame (CG coords) and new pinned state, for callers
    /// that want to flash a confirmation — nil if no window was found or the
    /// private API isn't available on this OS.
    @discardableResult
    func toggleFocusedWindow(of app: NSRunningApplication) -> (frame: CGRect, pinned: Bool)? {
        guard isAvailable else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        let axWindow = ref as! AXUIElement
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(axWindow, &wid) == .success,
              let frame = WindowManagerService.axFrame(of: axWindow) else { return nil }

        let pinned = !isPinned(wid)
        guard setPinned(pinned, windowID: wid) else { return nil }
        return (frame, pinned)
    }

    @discardableResult
    func setPinned(_ pinned: Bool, windowID: CGWindowID) -> Bool {
        guard let mainConnectionFn, let setLevelFn else { return false }
        let cid = mainConnectionFn()
        let level = pinned ? CGWindowLevelForKey(.floatingWindow) : CGWindowLevelForKey(.normalWindow)
        guard setLevelFn(cid, windowID, level) == 0 else { return false }
        if pinned { pinnedWindowIDs.insert(windowID) } else { pinnedWindowIDs.remove(windowID) }
        return true
    }
}
