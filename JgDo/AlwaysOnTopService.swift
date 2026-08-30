import AppKit
import ApplicationServices
import CoreGraphics

@_silgen_name("_AXUIElementGetWindow")
@discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: inout CGWindowID) -> AXError

@Observable
final class AlwaysOnTopService {
    static let shared = AlwaysOnTopService()

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SetLevelFn = @convention(c) (Int32, CGWindowID, Int32) -> Int32
    private let mainConnectionFn: MainConnectionFn?
    private let setLevelFn: SetLevelFn?

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
