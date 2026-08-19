import AppKit
import ApplicationServices

/// Single-slot "undo last snap/move" (⌃⌥Z) — not a full undo stack, just the
/// most recent frame change applied by a JgDo action (hotkey snap, shrink/
/// grow, or ⌘-drag-to-snap). Restores only if the window is still exactly
/// where that action left it — if the user has since moved/resized it by
/// hand (or the frontmost app changed it), ⌃⌥Z does nothing rather than
/// clobbering an unrelated later change.
final class WindowSnapUndo {
    static let shared = WindowSnapUndo()
    private init() {}

    private var axWindow: AXUIElement?
    private var previousFrame: CGRect?   // CG coords (top-left origin)
    private var appliedFrame: CGRect?

    /// Called right after a snap/resize is applied. `previous` is the
    /// window's frame *before* the action; `applied` is what was actually
    /// set (read back — some apps clamp size/position to their own minimum).
    func record(axWindow: AXUIElement, previous: CGRect, applied: CGRect) {
        self.axWindow = axWindow
        self.previousFrame = previous
        self.appliedFrame = applied
    }

    /// Restores the window to its pre-action frame. Returns false (does
    /// nothing) if there's nothing recorded, or if the window has since
    /// moved away from where the last action left it. One-shot either way —
    /// a second ⌃⌥Z press doesn't redo/toggle back.
    @discardableResult
    func undo() -> Bool {
        defer { axWindow = nil; previousFrame = nil; appliedFrame = nil }
        guard let axWindow, let previousFrame, let appliedFrame,
              let current = WindowManagerService.axFrame(of: axWindow),
              approximatelyEqual(current, appliedFrame) else { return false }
        WindowManagerService.setAXFrame(previousFrame, of: axWindow)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        return true
    }

    private func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 24) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }
}
