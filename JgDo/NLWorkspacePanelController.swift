import AppKit
import SwiftUI

/// Owns the Natural-Language Workspace panel (⌃⌥⇧N, or `>ai` — see
/// `AppDelegate`). Mirrors `OrganizePanelController` almost exactly:
/// rebuilds the root view fresh on every show since its content (the
/// current-window snapshot) is a live moment-in-time capture, not
/// something an `@Observable` service can just keep current on its own.
@MainActor
final class NLWorkspacePanelController {
    private var panel: NSPanel?
    private var keyMonitor: Any?

    func setup() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
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
        guard AppSettings.nlWorkspaceEnabled, let screen = NSScreen.main else { return }

        let windows = WindowManagerService().fetchWindows()
        let installedNames = CommandPaletteState.installedApps.map { $0.name }

        let rootView = NLWorkspaceView(
            installedAppNames: installedNames, screen: screen, currentWindows: windows,
            onApply: { [weak self] validated in self?.apply(validated) },
            onCancel: { [weak self] in self?.hide() }
        )
        panel.contentViewController = NSHostingController(rootView: rootView)

        let pw: CGFloat = 560, ph: CGFloat = 360
        let x = screen.frame.minX + (screen.frame.width - pw) / 2
        let y = screen.frame.minY + (screen.frame.height - ph) / 2
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

    private func apply(_ validated: WorkspaceCommandExecutor.ValidatedCommand) {
        hide()
        Task {
            await WorkspaceCommandExecutor.shared.execute(validated)
        }
    }

    private func hide() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.orderOut(nil)
    }
}
