import AppKit
import SwiftUI

/// Owns the scratchpad panel (⌃⌥N) — a small floating notes window,
/// entirely self-contained (no cross-panel coordination needed, unlike the
/// HUD/clipboard/command-palette cluster which hide each other). Extracted
/// from `AppDelegate` verbatim; behavior is unchanged.
@MainActor
final class ScratchpadPanelController {
    private var panel: NSPanel?
    private var keyMonitor: Any?

    func setup() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 260),
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
        let rootView = ScratchpadView(onDismiss: { [weak self] in self?.hide() })
        panel.contentViewController = NSHostingController(rootView: rootView)
        self.panel = panel
    }

    func toggle() {
        guard let panel else { return }
        if panel.isVisible { hide(); return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let pw: CGFloat = 320, ph: CGFloat = 260
        let x = screen.frame.minX + (screen.frame.width - pw) / 2
        let y = screen.frame.minY + (screen.frame.height - ph) / 2 + screen.frame.height * 0.1
        panel.setFrame(NSRect(x: x, y: y, width: pw, height: ph), display: true)
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
