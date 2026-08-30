import SwiftUI

/// A tiny visual diagram of a `WindowLayout` — an outer bordered rectangle
/// with a filled sub-region showing where the window will end up, instead
/// of relying on the reader to know what "2/3 Left" or "Top Right" means
/// from the name alone. Used everywhere a layout is shown: Command Palette
/// layout-command rows, the Shortcut Cheat Sheet, Settings → Shortcuts, and
/// the `LayoutPickerView` grid — one definition, so all four stay visually
/// consistent and a new layout added to `WindowLayout` only needs its
/// fraction added here once.
///
/// Deliberately hand-drawn with `RoundedRectangle`/`GeometryReader` rather
/// than `WindowLayout.icon`'s SF Symbol names: those symbols were never
/// actually wired to any UI (dead code), and drawing the diagram directly
/// guarantees it renders correctly on macOS 14 regardless of which SF
/// Symbols version introduced a given glyph, and lets it pick up the
/// exact accent color the rest of the app's panels already use.
struct LayoutPreviewIcon: View {
    let layout: WindowLayout
    var color: Color = .accentColor
    /// Overrides the highlighted region instead of deriving it from
    /// `layout` alone — used by the ⌃⌥←/→ layout-cycle overlay, whose steps
    /// include fractions (e.g. "Left Third") that a bare `WindowLayout`
    /// case doesn't encode. `nil` (every existing call site) keeps the
    /// original behavior exactly.
    var unitOverride: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let f = unitOverride ?? Self.fraction(for: layout)
            ZStack {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(color.opacity(0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(color.opacity(0.85))
                    .frame(width: max(w * f.width - 2, 1), height: max(h * f.height - 2, 1))
                    .position(x: w * (f.x + f.width / 2), y: h * (f.y + f.height / 2))
            }
        }
        // The row/tile this sits in always carries the same information as
        // its own text label ("Left Half", "Snap Safari Left Half", …) —
        // this diagram is a redundant visual reinforcement of that label,
        // not new information, so VoiceOver skips straight to the label.
        .accessibilityHidden(true)
    }

    /// Fractional (x, y, width, height) of the highlighted region within
    /// the outer box, top-left origin (SwiftUI's own convention for this
    /// purely decorative diagram — not tied to real AppKit/CG screen
    /// coordinates, which use bottom-left origin).
    static func fraction(for layout: WindowLayout) -> (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        switch layout {
        case .leftHalf:    return (0, 0, 0.5, 1)
        case .rightHalf:   return (0.5, 0, 0.5, 1)
        case .topHalf:     return (0, 0, 1, 0.5)
        case .bottomHalf:  return (0, 0.5, 1, 0.5)
        case .topLeft:     return (0, 0, 0.5, 0.5)
        case .topRight:    return (0.5, 0, 0.5, 0.5)
        case .bottomLeft:  return (0, 0.5, 0.5, 0.5)
        case .bottomRight: return (0.5, 0.5, 0.5, 0.5)
        case .maximize:    return (0.06, 0.06, 0.88, 0.88)
        case .center:      return (0.2, 0.2, 0.6, 0.6)
        }
    }
}
