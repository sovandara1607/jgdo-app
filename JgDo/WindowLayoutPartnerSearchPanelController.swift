import AppKit
import SwiftUI

/// Owns the Tab-triggered "pick a window for the other half" panel —
/// mirrors the Command Palette's own shape (`KeyablePanel` + a local key
/// monitor for arrow/Enter/Escape, real text-field focus for typing)
/// instead of the CGEventTap-driven modifier-hold flow the layout-cycle
/// overlay itself uses — by the time this is up, the primary window is
/// already committed and the gesture has already ended.
@MainActor
final class WindowLayoutPartnerSearchPanelController {
    static let shared = WindowLayoutPartnerSearchPanelController()

    private var panel: NSPanel?
    private let state = WindowLayoutPartnerSearchState()
    private var keyMonitor: Any?
    private var pendingApply: ((PartnerWindowCandidate) -> Void)?

    private init() {}

    /// `complement`/`fraction` are the layout/fraction to apply to whichever
    /// window gets picked — the exact complement of the primary window's
    /// just-committed step (see `WindowLayoutSelectorController`).
    func show(complement: WindowLayout, fraction: CGFloat, excludingPID: pid_t,
              preselectPID: pid_t?, on screen: NSScreen) {
        state.reload(excludingPID: excludingPID, preselect: preselectPID)
        let excludingBundleID = NSRunningApplication(processIdentifier: excludingPID)?.bundleIdentifier
        pendingApply = { candidate in
            guard let app = NSRunningApplication(processIdentifier: candidate.pid) else { return }
            if let result = WindowResizeService.shared.resize(app: app, to: complement, fraction: fraction) {
                // An explicit pick is an even stronger pairing signal than
                // an auto-fill — reinforce it the same way.
                WindowPairService.shared.record(excludingBundleID, app.bundleIdentifier)
                if AppSettings.placementPreviewEnabled {
                    SnapPreviewOverlay.shared.show(primary: result.frame, secondary: nil, on: result.screen)
                }
            }
        }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let hosting = panel.contentViewController as! NSHostingController<WindowLayoutPartnerSearchView>
        hosting.rootView = WindowLayoutPartnerSearchView(state: state, complementName: complement.rawValue) { [weak self] candidate in
            self?.previewSelection(candidate, complement: complement, fraction: fraction, on: screen)
        }
        // Forces the rootView swap above to actually flush into a layout
        // pass before trusting the size — see the same fix in
        // `WindowLayoutSelectorOverlay.show`/`WindowActionHUD.show`.
        hosting.view.layoutSubtreeIfNeeded()
        let fitted = hosting.view.fittingSize
        let origin = NSPoint(x: screen.frame.midX - fitted.width / 2, y: screen.frame.midY - fitted.height / 2)
        panel.setFrame(NSRect(origin: origin, size: fitted), display: true)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    /// Ghosts the currently-highlighted candidate's target frame as soon as
    /// the highlight changes (arrow keys or typing) — so the workflow is
    /// "arrow to a row → see it previewed → Return to commit," not just
    /// "pick blind, then see the result." Non-mutating: nothing here
    /// touches a real window until `pendingApply` fires.
    private func previewSelection(_ candidate: PartnerWindowCandidate?, complement: WindowLayout,
                                   fraction: CGFloat, on screen: NSScreen) {
        guard AppSettings.placementPreviewEnabled, candidate != nil else { return }
        let frame = WindowResizeService.shared.previewFrame(for: complement, fraction: fraction, on: screen)
        SnapPreviewOverlay.shared.show(primary: frame, secondary: nil, on: screen)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(
            rootView: WindowLayoutPartnerSearchView(state: state, complementName: ""))
        return panel
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true else { return event }
            switch event.keyCode {
            case 126: self.state.move(-1); return nil   // ↑
            case 125: self.state.move(1);  return nil   // ↓
            case 36, 76:                                 // Return / Enter
                if let candidate = self.state.selected { self.pendingApply?(candidate) }
                self.hide()
                return nil
            case 53: self.hide(); return nil             // Esc — skip, no partner change
            default: return event                        // typing → search field
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func hide() {
        removeKeyMonitor()
        panel?.orderOut(nil)
        pendingApply = nil
    }
}
