import AppKit
import CoreGraphics
import ApplicationServices

struct WindowInfo: Identifiable, Hashable {
    let id = UUID()
    let windowID: CGWindowID
    let appName: String
    let windowTitle: String
    let pid: pid_t
    let icon: NSImage?
    let bounds: CGRect
    /// Which display this window is on, e.g. "Built-in Retina Display" — nil
    /// when there's only one screen connected (not worth showing then).
    /// Set by `WindowManagerService.fetchWindows()`.
    var screenLabel: String? = nil
    /// Set only for a synthetic row representing one background browser tab
    /// (see `BrowserTabService`) — the real on-screen window is `windowID`;
    /// this is the specific `AXTabs` element to `AXPress` on pick, so
    /// selecting the row switches to that tab instead of just focusing
    /// whichever tab happened to be active.
    var axTabElement: AXUIElement? = nil

    func hash(into hasher: inout Hasher) { hasher.combine(windowID) }
    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool { lhs.windowID == rhs.windowID }
}
