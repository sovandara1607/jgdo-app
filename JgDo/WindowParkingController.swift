import AppKit

/// Parks the frontmost window (⌃⌥P) — no panel of its own (that's
/// `WindowParkingService`'s persisted list, shown elsewhere), just the
/// "capture + flash a confirmation" action. Extracted from `AppDelegate`
/// verbatim; behavior is unchanged.
@MainActor
final class WindowParkingController {
    /// Parks the frontmost app's focused window, flashing a confirmation
    /// on top of the ghost-preview reticle used elsewhere.
    func parkFrontmostWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // Read the frame BEFORE parking (park minimizes it) for the flash.
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        var appKitFrame: CGRect?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
           let ref, let cgFrame = WindowManagerService.axFrame(of: ref as! AXUIElement) {
            appKitFrame = CoordinateSpace.appKit(fromCG: cgFrame)
        }
        guard WindowParkingService.shared.park(app) != nil else { return }
        if let appKitFrame {
            let screen = NSScreen.main ?? NSScreen.screens[0]
            SnapPreviewOverlay.shared.show(primary: appKitFrame, secondary: nil, indicator: "Parked", on: screen)
        }
    }
}
