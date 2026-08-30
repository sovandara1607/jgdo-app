import AppKit
import SwiftUI

/// Owns the Workspace Templates panel — same `KeyablePanel` chrome as the
/// other panels in this app.
@MainActor
final class WorkspaceTemplatesPanelController {
    private var panel: NSPanel?

    func setup() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
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

    func show() {
        guard let panel, let screen = NSScreen.main else { return }
        if panel.isVisible { return }

        let rootView = WorkspaceTemplatesView(
            onApply: { [weak self] template in
                self?.hide()
                Task { await WorkspaceTemplateService.shared.apply(template) }
            },
            onCancel: { [weak self] in self?.hide() }
        )
        panel.contentViewController = NSHostingController(rootView: rootView)

        let pw: CGFloat = 420, ph: CGFloat = 420
        let x = screen.frame.midX - pw / 2
        let y = screen.frame.midY - ph / 2
        panel.setFrame(NSRect(x: x, y: y, width: pw, height: ph), display: true)
        panel.invalidateShadow()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
