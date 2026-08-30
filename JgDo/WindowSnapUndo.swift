import AppKit
import ApplicationServices

/// One window's frame change within a `WindowLayoutTransaction`. Keyed by
/// its live `AXUIElement` — not a title or index, both of which can change
/// out from under an action — so a stale/dead reference just safely fails
/// `WindowSnapUndo`'s "is it still where I left it" check instead of
/// restoring the wrong window.
struct WindowFrameChange {
    let axWindow: AXUIElement
    let before: CGRect   // CG coords (top-left origin)
    let after: CGRect
}

/// One JgDo action's full set of frame changes — a ⌃⌥←/→ dual-snap
/// produces two (primary + auto-filled partner) so ⌃⌥Z restores both
/// together; a single-window snap/shrink/grow/drag produces one.
struct WindowLayoutTransaction {
    let timestamp: Date
    var changes: [WindowFrameChange]
}

/// Bounded "undo last window layout" (⌃⌥Z) history. Only `undo()` (pops
/// the most recent transaction) is exposed today — there's no multi-level
/// undo/redo UI — but keeping the underlying store as a bounded stack
/// rather than a single slot means that's a straightforward addition
/// later without another data-model change. Each entry restores only if
/// its window is still exactly where the transaction left it — if the
/// user has since moved/resized it by hand, that one entry is skipped
/// rather than clobbering an unrelated later change (the rest of the
/// transaction still restores; one closed app/missing window never blocks
/// restoring the others).
final class WindowSnapUndo {
    static let shared = WindowSnapUndo()
    private init() {}

    /// Capped so a long session's worth of snaps can't grow this
    /// unbounded — the oldest transaction just falls off once full.
    private static let maxHistory = 20

    private var history: [WindowLayoutTransaction] = []
    /// The transaction currently being built while grouping — `record`
    /// appends to it; `endTransaction()` pushes it onto `history`. A bare
    /// `record` outside any begin/end bracket (the common single-window
    /// case) instead pushes its own self-contained one-change transaction
    /// immediately.
    private var inProgress: WindowLayoutTransaction?
    private var isGrouping = false

    /// Starts grouping every `record` call until `endTransaction()` into
    /// one atomic undo unit. Call around a dual-snap's primary + partner
    /// resize calls.
    func beginTransaction() {
        isGrouping = true
        inProgress = WindowLayoutTransaction(timestamp: Date(), changes: [])
    }

    func endTransaction() {
        isGrouping = false
        if let t = inProgress { push(t) }
        inProgress = nil
    }

    /// Called right after a snap/resize is applied. `previous` is the
    /// window's frame *before* the action; `applied` is what was actually
    /// set (read back — some apps clamp size/position to their own minimum).
    func record(axWindow: AXUIElement, previous: CGRect, applied: CGRect) {
        let change = WindowFrameChange(axWindow: axWindow, before: previous, after: applied)
        if isGrouping {
            inProgress?.changes.append(change)
        } else {
            push(WindowLayoutTransaction(timestamp: Date(), changes: [change]))
        }
    }

    private func push(_ transaction: WindowLayoutTransaction) {
        guard !transaction.changes.isEmpty else { return }
        history.append(transaction)
        if history.count > Self.maxHistory {
            history.removeFirst(history.count - Self.maxHistory)
        }
    }

    /// Restores every window in the most recent transaction to its
    /// pre-action frame, then discards it unconditionally — including when
    /// nothing actually restored (every window in it moved away since).
    /// Discarding either way means a stale, fully-stale-since-then
    /// transaction can never get "stuck" at the top of the stack blocking
    /// access to the transaction before it; a second ⌃⌥Z press always
    /// tries the next one back, never repeats the same failed attempt.
    @discardableResult
    func undo() -> Bool {
        guard let last = history.popLast() else { return false }
        var restoredAny = false
        for change in last.changes {
            guard let current = WindowManagerService.axFrame(of: change.axWindow),
                  approximatelyEqual(current, change.after) else { continue }
            WindowManagerService.setAXFrame(change.before, of: change.axWindow)
            AXUIElementPerformAction(change.axWindow, kAXRaiseAction as CFString)
            restoredAny = true
        }
        return restoredAny
    }

    private func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 24) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }
}
