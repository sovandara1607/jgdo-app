import CoreGraphics

/// Pure geometry for ambient window magnetism — gentle edge alignment while
/// dragging or resizing with a plain (no-⌘) mouse drag. Distinct from
/// `SnapEngine`, which drives the ⌘-held "snap into available space" and
/// "resize adjacent windows" features; magnetism is always-on by default
/// and just nudges edges into alignment as they pass near a magnet point,
/// rather than computing a whole leftover-space rectangle.
///
/// Same design constraints as `SnapEngine`: no AppKit/AX dependency, one
/// shared CG global coordinate space (top-left origin) matching AX
/// position/size attributes directly, and cheap enough to call on every
/// drag tick. Reuses `SnapEngine.Edge`/`EdgeMovement` rather than
/// duplicating them.
enum WindowMagnetismEngine {

    private struct AxisCandidate { let position: CGFloat; let distance: CGFloat }

    // MARK: - Move (whole frame translates; size stays fixed)

    /// The snapped origin for a MOVE, computed independently per axis — X
    /// and Y each either land on their own nearest magnet point (within
    /// `distance`) or stay wherever the cursor put them. `gap` is added to
    /// every "flush against" candidate (window-to-window and screen-edge
    /// alike) so a magnetically-snapped window lands with the same padding
    /// hotkey tiling already uses — pass `AppSettings.edgeGap`.
    static func snappedOrigin(
        for frame: CGRect,
        candidates: [CGRect],
        screenBounds: CGRect,
        distance: CGFloat,
        gap: CGFloat
    ) -> CGPoint? {
        guard distance > 0 else { return nil }
        let x = snappedAxisOrigin(
            current: frame.minX, size: frame.width, span: (frame.minY, frame.maxY),
            candidates: candidates, screenMin: screenBounds.minX, screenMax: screenBounds.maxX,
            distance: distance, gap: gap, horizontal: true
        )
        let y = snappedAxisOrigin(
            current: frame.minY, size: frame.height, span: (frame.minX, frame.maxX),
            candidates: candidates, screenMin: screenBounds.minY, screenMax: screenBounds.maxY,
            distance: distance, gap: gap, horizontal: false
        )
        guard x != nil || y != nil else { return nil }
        return CGPoint(x: x ?? frame.minX, y: y ?? frame.minY)
    }

    private static func snappedAxisOrigin(
        current: CGFloat, size: CGFloat, span: (CGFloat, CGFloat),
        candidates: [CGRect], screenMin: CGFloat, screenMax: CGFloat,
        distance: CGFloat, gap: CGFloat, horizontal: Bool
    ) -> CGFloat? {
        var best: AxisCandidate?
        func consider(_ position: CGFloat) {
            let d = abs(position - current)
            guard d <= distance else { return }
            if best == nil || d < best!.distance { best = AxisCandidate(position: position, distance: d) }
        }

        // Screen bounds, inset by the tiling gap — consistent with hotkey tiling.
        consider(screenMin + gap)
        consider(screenMax - size - gap)

        for candidate in candidates {
            let cSpan = horizontal ? (candidate.minY, candidate.maxY) : (candidate.minX, candidate.maxX)
            guard overlaps(span, cSpan) else { continue }
            let cMin = horizontal ? candidate.minX : candidate.minY
            let cMax = horizontal ? candidate.maxX : candidate.maxY
            consider(cMax + gap)         // flush against the candidate's far edge
            consider(cMin)                // aligned with the candidate's near edge
            consider(cMin - gap - size)   // flush against the candidate's near edge, from the other side
            consider(cMax - size)         // aligned with the candidate's far edge
        }
        return best?.position
    }

    // MARK: - Resize (only one edge moves; the opposite edge is fixed)

    /// The snapped position for a single moving edge during a resize, or
    /// nil if nothing is within `distance`.
    static func snappedEdge(
        _ edge: SnapEngine.Edge,
        frame: CGRect,
        candidates: [CGRect],
        screenBounds: CGRect,
        distance: CGFloat,
        gap: CGFloat
    ) -> CGFloat? {
        guard distance > 0 else { return nil }
        switch edge {
        case .left, .right:
            return snappedSingleEdge(
                current: edge == .left ? frame.minX : frame.maxX, span: (frame.minY, frame.maxY),
                candidates: candidates, screenMin: screenBounds.minX, screenMax: screenBounds.maxX,
                distance: distance, gap: gap, horizontal: true, isMinEdge: edge == .left
            )
        case .top, .bottom:
            return snappedSingleEdge(
                current: edge == .top ? frame.minY : frame.maxY, span: (frame.minX, frame.maxX),
                candidates: candidates, screenMin: screenBounds.minY, screenMax: screenBounds.maxY,
                distance: distance, gap: gap, horizontal: false, isMinEdge: edge == .top
            )
        }
    }

    private static func snappedSingleEdge(
        current: CGFloat, span: (CGFloat, CGFloat),
        candidates: [CGRect], screenMin: CGFloat, screenMax: CGFloat,
        distance: CGFloat, gap: CGFloat, horizontal: Bool, isMinEdge: Bool
    ) -> CGFloat? {
        var best: AxisCandidate?
        func consider(_ position: CGFloat) {
            let d = abs(position - current)
            guard d <= distance else { return }
            if best == nil || d < best!.distance { best = AxisCandidate(position: position, distance: d) }
        }

        consider(isMinEdge ? screenMin + gap : screenMax - gap)

        for candidate in candidates {
            let cSpan = horizontal ? (candidate.minY, candidate.maxY) : (candidate.minX, candidate.maxX)
            guard overlaps(span, cSpan) else { continue }
            let cMin = horizontal ? candidate.minX : candidate.minY
            let cMax = horizontal ? candidate.maxX : candidate.maxY
            if isMinEdge {
                consider(cMax + gap)   // flush against the candidate's far edge
                consider(cMin)          // aligned with the candidate's near edge
            } else {
                consider(cMin - gap)    // flush against the candidate's near edge
                consider(cMax)          // aligned with the candidate's far edge
            }
        }
        return best?.position
    }

    // MARK: - Equal-size nudge (lightweight polish)

    /// If `frame`'s width (or height) is within `tolerance` of a nearby
    /// candidate's — but not already exactly equal — returns the exact
    /// matching dimension, so "these two windows are basically the same
    /// size" becomes "exactly the same size."
    static func matchingDimension(
        of frame: CGRect, candidates: [CGRect], tolerance: CGFloat, horizontal: Bool
    ) -> CGFloat? {
        let current = horizontal ? frame.width : frame.height
        for candidate in candidates {
            let other = horizontal ? candidate.width : candidate.height
            let delta = abs(other - current)
            if delta > 0.5 && delta <= tolerance { return other }
        }
        return nil
    }

    private static func overlaps(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> Bool {
        a.0 < b.1 && a.1 > b.0
    }
}
