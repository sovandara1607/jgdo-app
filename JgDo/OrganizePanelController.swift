import AppKit
import SwiftUI

/// Owns the "Organize Workspace" preview panel (⌃⌥O). Extracted from
/// `AppDelegate` verbatim; behavior is unchanged. Unlike the other panel
/// controllers, this one rebuilds its root view fresh on every show (its
/// content depends on live workspace state snapshotted at open time, not
/// an `@Observable` service the view can just read).
@MainActor
final class OrganizePanelController {
    private var panel: NSPanel?
    private var keyMonitor: Any?

    func setup() {
        let panel = KeyablePanel(
            // Matches `OrganizeWorkspaceView`'s own `.frame(width: 560, ...)`
            // — see the comment there for why 420 was too narrow.
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
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
        self.panel = panel
    }

    /// Snapshots the current windows fresh each time and rebuilds the view
    /// with that snapshot.
    func toggle() {
        guard let panel else { return }
        if panel.isVisible { hide(); return }

        let windows = WindowManagerService().fetchWindows()
        guard !windows.isEmpty, let screen = NSScreen.main else { return }

        let rootView = OrganizeWorkspaceView(
            windows: windows, screen: screen,
            onApply: { [weak self] mode in
                self?.apply(mode: mode, windows: windows, screen: screen)
            },
            onCancel: { [weak self] in self?.hide() }
        )
        panel.contentViewController = NSHostingController(rootView: rootView)

        let pw: CGFloat = 420, ph: CGFloat = 300
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

    private func apply(mode: OrganizeMode, windows: [WindowInfo], screen: NSScreen) {
        // "before" snapshot for undo, taken from the same fetch the preview
        // was built from.
        OrganizeUndoService.shared.record(windows.map { ($0, $0.appKitFrame) })
        let proposed = OrganizeWorkspaceService.propose(mode: mode, windows: windows, on: screen)
        let svc = WindowManagerService()
        for (window, frame) in proposed {
            svc.applyFrame(frame, to: window, on: screen)
        }
        ActionToastCenter.shared.show("\(proposed.count) Windows Organized", icon: "square.grid.2x2")
        hide()
    }

    private func hide() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.orderOut(nil)
    }
}
