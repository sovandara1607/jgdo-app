import AppKit
import SwiftUI

/// Owns the shortcuts cheat sheet panel (⌃⌥/) — self-contained, same
/// pattern as `ScratchpadPanelController`. Extracted from `AppDelegate`
/// verbatim; behavior is unchanged.
@MainActor
final class CheatSheetPanelController {
    private var panel: NSPanel?
    private var keyMonitor: Any?

    func setup() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
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
        // Native window shadow OFF — SwiftUI's own `.panelCard()` shadow is
        // the only one now. Having both caused a jagged double-shadow seam
        // at the rounded corners during the alpha fade-in (the native shadow
        // rasterizes against stale corner geometry mid-animation).
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: ShortcutCheatSheetView())
        self.panel = panel
    }

    func toggle() {
        guard let panel else { return }
        if panel.isVisible { hide(); return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let pw: CGFloat = 340, ph: CGFloat = 420
        let x = screen.frame.minX + (screen.frame.width - pw) / 2
        let y = screen.frame.minY + (screen.frame.height - ph) / 2
        panel.setFrame(NSRect(x: x, y: y, width: pw, height: ph), display: true)
        // Without this, the shadow mask AppKit cached at creation stays
        // stale after the resize — shows up as a jagged dark outline
        // ghosting the panel's original placeholder frame.
        panel.invalidateShadow()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true else { return event }
            if event.keyCode == 53 { self.hide(); return nil }   // Esc
            return event
        }
    }

    private func hide() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.orderOut(nil)
    }
}
