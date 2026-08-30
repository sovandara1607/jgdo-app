import AppKit
import SwiftUI

/// Owns the visual Layout Picker panel (⌃⌥⇧L). Mirrors
/// `NLWorkspacePanelController`/`OrganizePanelController` almost exactly —
/// same `KeyablePanel` chrome, same "rebuild the root view fresh on every
/// show" approach, since which app to target is captured fresh each time
/// (the frontmost app at the moment the hotkey fired, before this panel
/// itself steals key focus).
@MainActor
final class LayoutPickerPanelController {
    private var panel: NSPanel?
    private var targetApp: NSRunningApplication?

    func setup() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
    }

    func toggle() {
        guard let panel else { return }
        if panel.isVisible { hide(); return }

        // Resolved via `fetchWindows()` (front-to-back z-order, JgDo's own
        // windows already excluded) rather than
        // `NSWorkspace.shared.frontmostApplication` — this controller is
        // reachable both from the global hotkey (where "frontmost app" is
        // unambiguous) AND from a button inside JgDo's own popover, where
        // JgDo itself can transiently read as frontmost. `fetchWindows()`
        // is the same target-resolution `OrganizePanelController`/
        // `NLWorkspacePanelController` already rely on for exactly this
        // reason.
        guard let window = WindowManagerService().fetchWindows().first,
              let app = NSRunningApplication(processIdentifier: window.pid),
              let screen = NSScreen.main else { return }
        targetApp = app

        let rootView = LayoutPickerView(
            targetAppName: app.localizedName ?? "the frontmost app",
            targetIcon: app.icon,
            onPick: { [weak self] layout in self?.apply(layout) },
            onCancel: { [weak self] in self?.hide() }
        )
        panel.contentViewController = NSHostingController(rootView: rootView)

        let pw: CGFloat = 360, ph: CGFloat = 190
        let x = screen.frame.midX - pw / 2
        let y = screen.frame.midY - ph / 2
        panel.setFrame(NSRect(x: x, y: y, width: pw, height: ph), display: true)
        panel.invalidateShadow()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func apply(_ layout: WindowLayout) {
        if let app = targetApp, let screen = NSScreen.main {
            WindowResizeService.shared.resize(app: app, to: layout)
            WindowActionHUD.shared.show(appIcon: app.icon, appName: app.localizedName ?? "Window",
                                         layout: layout, on: screen)
        }
        hide()
    }

    private func hide() {
        SnapPreviewOverlay.shared.hidePersistent()
        panel?.orderOut(nil)
        targetApp = nil
    }
}
