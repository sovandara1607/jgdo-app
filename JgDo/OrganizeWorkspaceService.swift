import AppKit

/// Deterministic layout strategies for "Clean Workspace" — every mode is a
/// pure function from (current on-screen windows, target screen) → proposed
/// AppKit frames. No AI/heuristic guessing about what's "related" — the
/// spec is explicit that automatic grouping/suggestion is future work.
enum OrganizeMode: String, CaseIterable, Identifiable {
    case balanced, focus, columns, rows, mainStack

    var id: String { rawValue }

    var label: String {
        switch self {
        case .balanced:  return "Balanced"
        case .focus:     return "Focus"
        case .columns:   return "Columns"
        case .rows:      return "Rows"
        case .mainStack: return "Main + Stack"
        }
    }
}

enum OrganizeWorkspaceService {
    /// Proposed (window, frame) pairs for the current on-screen windows
    /// (front-to-back), laid out on `screen` per `mode`. Frames are AppKit
    /// coords, ready for `WindowManagerService.applyFrame`.
    static func propose(mode: OrganizeMode, windows: [WindowInfo], on screen: NSScreen) -> [(WindowInfo, CGRect)] {
        guard !windows.isEmpty else { return [] }
        let area = screen.visibleFrame
        switch mode {
        case .balanced:  return balanced(windows, area: area)
        case .columns:   return columns(windows, area: area)
        case .rows:      return rowsLayout(windows, area: area)
        case .focus, .mainStack: return mainPlusStack(windows, area: area)
        }
    }

    /// A roughly-square grid: `ceil(sqrt(n))` columns, rows filled left to
    /// right, top to bottom. The most broadly "clean" default for an
    /// arbitrary mix of windows.
    private static func balanced(_ windows: [WindowInfo], area: CGRect) -> [(WindowInfo, CGRect)] {
        let n = windows.count
        let cols = Int(ceil(sqrt(Double(n))))
        let rows = Int(ceil(Double(n) / Double(cols)))
        let cellW = area.width / CGFloat(cols)
        let cellH = area.height / CGFloat(rows)
        return windows.enumerated().map { i, w in
            let col = i % cols, row = i / cols
            // Last row may have fewer items than `cols` — stretch them to
            // fill the row's width evenly instead of leaving a gap.
            let itemsInRow = min(cols, n - row * cols)
            let thisCellW = area.width / CGFloat(itemsInRow)
            let frame = CGRect(x: area.minX + CGFloat(col) * thisCellW,
                                y: area.maxY - CGFloat(row + 1) * cellH,
                                width: thisCellW, height: cellH)
            return (w, frame)
        }
    }

    /// N equal-width, full-height columns, left to right (z-order).
    private static func columns(_ windows: [WindowInfo], area: CGRect) -> [(WindowInfo, CGRect)] {
        let n = windows.count
        let w = area.width / CGFloat(n)
        return windows.enumerated().map { i, win in
            (win, CGRect(x: area.minX + CGFloat(i) * w, y: area.minY, width: w, height: area.height))
        }
    }

    /// N equal-height, full-width rows, top to bottom (z-order).
    private static func rowsLayout(_ windows: [WindowInfo], area: CGRect) -> [(WindowInfo, CGRect)] {
        let n = windows.count
        let h = area.height / CGFloat(n)
        return windows.enumerated().map { i, win in
            (win, CGRect(x: area.minX, y: area.maxY - CGFloat(i + 1) * h, width: area.width, height: h))
        }
    }

    /// One primary window (the frontmost — first in z-order) takes the
    /// left ~62%; the rest stack evenly in the remaining right column.
    /// "Focus" and "Main + Stack" are the same shape — the spec's own
    /// examples for both are visually identical, so this isn't duplicated.
    private static func mainPlusStack(_ windows: [WindowInfo], area: CGRect) -> [(WindowInfo, CGRect)] {
        guard windows.count > 1 else {
            return windows.map { ($0, area) }
        }
        let mainRatio: CGFloat = 0.62
        let mainWidth = area.width * mainRatio
        let stack = Array(windows.dropFirst())
        let stackH = area.height / CGFloat(stack.count)

        var result: [(WindowInfo, CGRect)] = [
            (windows[0], CGRect(x: area.minX, y: area.minY, width: mainWidth, height: area.height))
        ]
        for (i, w) in stack.enumerated() {
            let frame = CGRect(x: area.minX + mainWidth, y: area.maxY - CGFloat(i + 1) * stackH,
                                width: area.width - mainWidth, height: stackH)
            result.append((w, frame))
        }
        return result
    }
}

/// Records the "before" frames of an Organize operation so it can be
/// undone as one unit — distinct from `WindowSnapUndo` (single-window,
/// hotkey-driven), since Organize moves N windows at once.
final class OrganizeUndoService {
    static let shared = OrganizeUndoService()
    private init() {}

    private var snapshot: [(window: WindowInfo, previousFrame: CGRect)] = []
    private let windowService = WindowManagerService()

    func record(_ pairs: [(WindowInfo, CGRect)]) {
        snapshot = pairs.map { ($0.0, $0.1) }
    }

    var canUndo: Bool { !snapshot.isEmpty }

    func undo() {
        guard let screen = NSScreen.main else { return }
        for (window, frame) in snapshot {
            windowService.applyFrame(frame, to: window, on: screen)
        }
        snapshot = []
    }
}
