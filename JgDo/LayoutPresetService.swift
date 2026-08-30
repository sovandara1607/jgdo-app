import AppKit
import SwiftData

/// Saves/restores app-agnostic window-layout *shapes* — captures the
/// fractional geometry of whatever's currently on screen (front-to-back)
/// and can reapply that same shape later to whatever's on screen THEN,
/// regardless of which apps those happen to be. Distinct from
/// `WorkspaceService`, which remembers specific apps at specific absolute
/// positions (and launches them if not running).
///
/// Scoped to `NSScreen.main` for both capture and apply — keeping the
/// coordinate math single-screen avoids the ambiguity of "which screen does
/// slot 3 belong to" when the set of connected displays differs between
/// save and apply.
@Observable
final class LayoutPresetService {
    static let shared = LayoutPresetService()

    private(set) var presets: [LayoutPreset] = []
    private let windowService = WindowManagerService()

    private init() { reload() }

    func reload() {
        let ctx = Persistence.shared.context
        presets = ctx.fetchLogged(FetchDescriptor<LayoutPreset>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]), using: AppLog.workspace)
    }

    /// Captures the current on-screen windows (front-to-back z-order) as a
    /// named layout shape, fractions of `NSScreen.main`'s visible frame.
    @discardableResult
    func saveCurrentLayout(named name: String) -> LayoutPreset? {
        guard let screen = NSScreen.main else { return nil }
        let windows = windowService.fetchWindows()
        guard !windows.isEmpty else { return nil }

        let vf = screen.visibleFrame
        let ctx = Persistence.shared.context
        let preset = LayoutPreset(name: name)
        for (i, w) in windows.enumerated() {
            // `fetchWindows()` bounds are CG global coords (top-left
            // origin) — flip to AppKit global space via `CoordinateSpace`
            // (always keyed off the primary screen, never `screen.frame`
            // itself — `screen` here can be `NSScreen.main`, the screen
            // with keyboard focus, which is not necessarily the primary
            // display CG/AX global coordinates are anchored to), then
            // express as a fraction of the visible frame so it's
            // resolution/position independent.
            let appKit = CoordinateSpace.appKit(fromCG: w.bounds)
            let fraction = CGRect(x: (appKit.minX - vf.minX) / vf.width,
                                   y: (appKit.minY - vf.minY) / vf.height,
                                   width: appKit.width / vf.width,
                                   height: appKit.height / vf.height)
            let slot = LayoutSlot(fraction: fraction, orderIndex: i)
            slot.preset = preset
            preset.slots.append(slot)
            ctx.insert(slot)
        }
        ctx.insert(preset)
        Persistence.shared.save()
        reload()
        return preset
    }

    /// Reapplies `preset`'s shape to the CURRENT on-screen windows —
    /// slot 0 → frontmost window, slot 1 → next, etc. Extra saved slots (no
    /// matching window) or extra windows (no matching slot) are left alone.
    func apply(_ preset: LayoutPreset) {
        guard let screen = NSScreen.main else { return }
        let windows = windowService.fetchWindows()
        let vf = screen.visibleFrame
        let slots = preset.slots.sorted { $0.orderIndex < $1.orderIndex }
        for (window, slot) in zip(windows, slots) {
            let frame = CGRect(x: vf.minX + slot.fraction.minX * vf.width,
                                y: vf.minY + slot.fraction.minY * vf.height,
                                width: slot.fraction.width * vf.width,
                                height: slot.fraction.height * vf.height)
            windowService.applyFrame(frame, to: window, on: screen)
        }
    }

    func delete(_ preset: LayoutPreset) {
        Persistence.shared.context.delete(preset)
        Persistence.shared.save()
        reload()
    }

    func rename(_ preset: LayoutPreset, to name: String) {
        preset.name = name
        Persistence.shared.save()
        reload()
    }
}
