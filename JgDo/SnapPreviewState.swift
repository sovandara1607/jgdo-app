import AppKit

/// Drives the SwiftUI-rendered ghost preview shown during hotkey/drag window
/// snapping (`SnapPreviewContentView`). All rects are AppKit-local
/// (bottom-left origin), already offset to the destination screen's own
/// window — the same convention the overlay always used.
@Observable
final class SnapPreviewState {
    var primary: CGRect = .zero
    var secondary: CGRect?
    /// A divider bar marking a shared resize boundary (Feature 2).
    var guide: CGRect?
    /// An outline around a window explicitly Tab-picked mid-drag as the
    /// alignment target (Feature 1's Tab-to-pick mode).
    var highlight: CGRect?
    /// A short on-tile label — "2/3" for an edge-snap cycle step, "70%" for
    /// the shrink/grow preset steps — shown centered on the primary tile.
    var indicator: String?
    /// True for a discrete, one-off snap (hotkey flash) — animates the tile
    /// into position. False while a live ⌘-drag is continuously retargeting
    /// it every mouse-move tick, where animating would mean the spring is
    /// perpetually chasing a moving target (visible lag/wobble) instead of
    /// tracking the cursor directly, which is what actually reads as smooth.
    var animate: Bool = true
}
