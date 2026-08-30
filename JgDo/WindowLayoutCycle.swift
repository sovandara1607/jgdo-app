import Foundation

/// One step in the ⌃⌥←/→ "hold and cycle" layout overlay
/// (`WindowLayoutSelectorController`). Each step names a `WindowLayout`
/// JgDo already supports, plus (for the two "third" steps) the same
/// fraction the edge-snap hotkey cycle already uses — so there's exactly
/// one place that knows what "Left Third" means (this list) and one place
/// that turns it into pixels (`WindowResizeService.previewFrame`).
struct LayoutCycleStep: Equatable {
    enum Kind: Equatable {
        case layout(WindowLayout, fraction: CGFloat)
        case previousDisplay
        case nextDisplay
    }
    let name: String
    let kind: Kind

    /// Top-left-origin (SwiftUI) unit rect for the mini diagram — same
    /// visual convention `LayoutPreviewIcon.fraction(for:)` already uses for
    /// every other layout, just parametrized by this step's own fraction so
    /// e.g. "Left Third" draws a third-width highlight instead of always
    /// falling back to the plain half. `nil` for the two display-change
    /// steps, which the overlay renders with a dedicated glyph instead.
    var diagramUnit: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)? {
        guard case .layout(let layout, let fraction) = kind else { return nil }
        switch layout {
        case .leftHalf:  return (0, 0, fraction, 1)
        case .rightHalf: return (1 - fraction, 0, fraction, 1)
        default:         return LayoutPreviewIcon.fraction(for: layout)
        }
    }
}

/// Which arrow key started the current overlay session — determines which
/// ordered list of steps ← and → walk through. Mirrors of each other; edit
/// both sides together if the step set ever changes.
enum LayoutCycleFamily: Equatable {
    case left, right

    var steps: [LayoutCycleStep] {
        switch self {
        case .left:
            return [
                LayoutCycleStep(name: WindowLayout.leftHalf.rawValue, kind: .layout(.leftHalf, fraction: 0.5)),
                LayoutCycleStep(name: "Two Thirds Left", kind: .layout(.leftHalf, fraction: 2.0 / 3.0)),
                LayoutCycleStep(name: "Left Third", kind: .layout(.leftHalf, fraction: 1.0 / 3.0)),
                LayoutCycleStep(name: "Top Left Quarter", kind: .layout(.topLeft, fraction: 0.5)),
                LayoutCycleStep(name: "Bottom Left Quarter", kind: .layout(.bottomLeft, fraction: 0.5)),
                LayoutCycleStep(name: "Previous Display", kind: .previousDisplay),
            ]
        case .right:
            return [
                LayoutCycleStep(name: WindowLayout.rightHalf.rawValue, kind: .layout(.rightHalf, fraction: 0.5)),
                LayoutCycleStep(name: "Two Thirds Right", kind: .layout(.rightHalf, fraction: 2.0 / 3.0)),
                LayoutCycleStep(name: "Right Third", kind: .layout(.rightHalf, fraction: 1.0 / 3.0)),
                LayoutCycleStep(name: "Top Right Quarter", kind: .layout(.topRight, fraction: 0.5)),
                LayoutCycleStep(name: "Bottom Right Quarter", kind: .layout(.bottomRight, fraction: 0.5)),
                LayoutCycleStep(name: "Next Display", kind: .nextDisplay),
            ]
        }
    }

    /// Wrapping index math for "← = previous step, → = next step" within the
    /// active family's list — shared by the controller and its tests so the
    /// wrap-around behavior at either end can't drift between them.
    static func steppedIndex(_ index: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }
}
