import CoreGraphics

/// Pure geometry for drag-to-snap and adjacent resize. Deliberately free of
/// AppKit/AX dependencies so the math can be reasoned about independently of
/// live windows. All rects share one coordinate space — CG global coords,
/// top-left origin — matching `CGWindowListCopyWindowInfo` bounds, AX
/// position/size attributes, and `CGEvent.location` directly.
enum SnapEngine {

    enum Edge { case left, right, top, bottom }

    /// Last-resort floor so a neighbor never gets pushed to zero/negative
    /// size when we can't otherwise determine its true minimum.
    static let minNeighborDimension: CGFloat = 120

    // MARK: - Feature 1: Snap Into Available Space

    /// The largest empty rectangle containing `point`, bounded by `obstacles`
    /// and clipped to `bounds`.
    ///
    /// Greedy two-pass expansion: grow horizontally within the point's row
    /// first (bounded by the nearest obstacle edges that vertically overlap
    /// the point), then grow vertically using that resulting column (bounded
    /// by the nearest obstacle edges that horizontally overlap the column).
    /// This isn't the globally-maximal empty rectangle for every possible
    /// layout, but it is exact for simple edge/quadrant/thirds tiling and is
    /// cheap enough to recompute on every drag tick.
    static func availableSpace(at point: CGPoint, obstacles: [CGRect], in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return bounds }
        let clampedPoint = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                                    y: min(max(point.y, bounds.minY), bounds.maxY))
        let clipped: [CGRect] = obstacles.compactMap {
            let r = $0.intersection(bounds)
            return (r.isNull || r.width <= 0 || r.height <= 0) ? nil : r
        }

        // Pass 1: horizontal bounds at the cursor's row.
        var left = bounds.minX
        var right = bounds.maxX
        for ob in clipped where ob.minY <= clampedPoint.y && ob.maxY >= clampedPoint.y {
            if ob.maxX <= clampedPoint.x { left = max(left, ob.maxX) }
            if ob.minX >= clampedPoint.x { right = min(right, ob.minX) }
        }
        guard right > left else { return CGRect(x: clampedPoint.x, y: clampedPoint.y, width: 0, height: 0) }

        // Pass 2: vertical bounds using the resulting column.
        var top = bounds.minY
        var bottom = bounds.maxY
        for ob in clipped where overlaps(ob.minX, ob.maxX, left, right) {
            if ob.maxY <= clampedPoint.y { top = max(top, ob.maxY) }
            if ob.minY >= clampedPoint.y { bottom = min(bottom, ob.minY) }
        }
        guard bottom > top else { return CGRect(x: left, y: clampedPoint.y, width: right - left, height: 0) }

        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    // MARK: - Feature 1b: Tab-to-pick an explicit alignment target
    //
    // The cursor-driven `availableSpace(at:...)` above is the default: it
    // infers "which window to align next to" purely from where the mouse
    // happens to be. When the user explicitly picks a target window (by
    // pressing Tab mid-drag), we still want to reuse that same algorithm —
    // so instead of feeding it the raw cursor point, we feed it a point just
    // outside whichever side of the target is closest to the cursor. That
    // keeps "which of the target's 4 sides" mouse-driven and intuitive,
    // while "which window" is now explicit rather than inferred.

    /// Which side of `target` the cursor is closest to — used to decide
    /// which edge of a Tab-picked target window to align against.
    static func nearestSide(of target: CGRect, to point: CGPoint) -> Edge {
        if point.x < target.minX { return .left }
        if point.x > target.maxX { return .right }
        if point.y < target.minY { return .top }
        if point.y > target.maxY { return .bottom }
        // Cursor is within the target's bounds on both axes — fall back to
        // whichever edge it's nearest to.
        let dl = point.x - target.minX, dr = target.maxX - point.x
        let dt = point.y - target.minY, db = target.maxY - point.y
        let m = min(dl, dr, dt, db)
        if m == dl { return .left }
        if m == dr { return .right }
        if m == dt { return .top }
        return .bottom
    }

    /// A point just outside the given side of `target`, suitable as the
    /// anchor for `availableSpace(at:...)` when aligning against an
    /// explicitly-picked target rather than the raw cursor position.
    static func anchorPoint(adjacentTo target: CGRect, side: Edge, in bounds: CGRect) -> CGPoint {
        let inset: CGFloat = 4
        switch side {
        case .right:  return CGPoint(x: min(target.maxX + inset, bounds.maxX - 1), y: target.midY)
        case .left:   return CGPoint(x: max(target.minX - inset, bounds.minX + 1), y: target.midY)
        case .bottom: return CGPoint(x: target.midX, y: min(target.maxY + inset, bounds.maxY - 1))
        case .top:    return CGPoint(x: target.midX, y: max(target.minY - inset, bounds.minY + 1))
        }
    }

    // MARK: - Move vs. resize classification

    enum DragMode { case move, resize }

    /// Classifies a live frame against the frame captured at mouse-down.
    /// Returns nil until a real change has happened.
    ///
    /// The size threshold is deliberately higher than the origin threshold:
    /// real-world AX position/size reporting shows a couple of points of
    /// harmless settling jitter right as a title-bar drag begins (some apps'
    /// windows nudge their own size by 2-3pt on activation), and locking the
    /// whole gesture into `.resize` from that alone was misclassifying
    /// ordinary moves — the drag-to-snap picker/preview never ran for the
    /// rest of that drag as a result. A real resize reliably clears a wider
    /// margin within the same first couple of ticks, so this doesn't slow
    /// down genuine resize detection.
    static func classify(originalFrame: CGRect, liveFrame: CGRect,
                         moveTolerance: CGFloat = 1.5, resizeTolerance: CGFloat = 6) -> DragMode? {
        let sizeChanged = abs(liveFrame.width - originalFrame.width) > resizeTolerance
            || abs(liveFrame.height - originalFrame.height) > resizeTolerance
        let originChanged = abs(liveFrame.minX - originalFrame.minX) > moveTolerance
            || abs(liveFrame.minY - originalFrame.minY) > moveTolerance
        guard sizeChanged || originChanged else { return nil }
        // A left/top-edge resize moves the origin too, so any size change
        // past the (higher) resize threshold takes priority over a plain
        // origin shift.
        return sizeChanged ? .resize : .move
    }

    // MARK: - Feature 2: Resize Adjacent Windows

    struct EdgeMovement {
        let edge: Edge
        let oldPosition: CGFloat
        let newPosition: CGFloat
    }

    /// Which edges of the dragged window moved between `oldFrame` and `newFrame`.
    static func movedEdges(from oldFrame: CGRect, to newFrame: CGRect, tolerance: CGFloat = 1.5) -> [EdgeMovement] {
        var moves: [EdgeMovement] = []
        if abs(newFrame.minX - oldFrame.minX) > tolerance {
            moves.append(EdgeMovement(edge: .left, oldPosition: oldFrame.minX, newPosition: newFrame.minX))
        }
        if abs(newFrame.maxX - oldFrame.maxX) > tolerance {
            moves.append(EdgeMovement(edge: .right, oldPosition: oldFrame.maxX, newPosition: newFrame.maxX))
        }
        if abs(newFrame.minY - oldFrame.minY) > tolerance {
            moves.append(EdgeMovement(edge: .top, oldPosition: oldFrame.minY, newPosition: newFrame.minY))
        }
        if abs(newFrame.maxY - oldFrame.maxY) > tolerance {
            moves.append(EdgeMovement(edge: .bottom, oldPosition: oldFrame.maxY, newPosition: newFrame.maxY))
        }
        return moves
    }

    struct WindowSnapshot {
        let windowID: CGWindowID
        let frame: CGRect
    }

    struct NeighborResize {
        let windowID: CGWindowID
        let newFrame: CGRect
    }

    /// For each moved edge of the dragged window, finds other windows whose
    /// corresponding edge coincided with that edge's *original* position (and
    /// which overlap it on the perpendicular axis) — i.e. windows that were
    /// snapped flush against that edge before the drag began — and computes
    /// their new frame so the shared boundary stays flush.
    ///
    /// Neighbor detection is purely geometric; no persistent "snap graph" is
    /// tracked, so this works for any windows that happen to be tiled
    /// edge-to-edge, regardless of how they got that way.
    static func neighborResizes(
        originalFrame: CGRect,
        edgeMovements: [EdgeMovement],
        others: [WindowSnapshot],
        tolerance: CGFloat = 2.0
    ) -> [NeighborResize] {
        var results: [CGWindowID: CGRect] = [:]
        for move in edgeMovements {
            for other in others {
                guard let newFrame = resizedNeighborFrame(
                    for: other.frame, given: move,
                    originalDraggedFrame: originalFrame, tolerance: tolerance
                ) else { continue }
                results[other.windowID] = newFrame
            }
        }
        return results.map { NeighborResize(windowID: $0.key, newFrame: $0.value) }
    }

    private static func resizedNeighborFrame(
        for neighborFrame: CGRect,
        given move: EdgeMovement,
        originalDraggedFrame: CGRect,
        tolerance: CGFloat
    ) -> CGRect? {
        switch move.edge {
        case .right:
            // Dragged window's right edge moved; a neighbor to its right
            // whose left edge matched keeps its own right edge fixed.
            guard abs(neighborFrame.minX - move.oldPosition) <= tolerance,
                  overlaps(neighborFrame.minY, neighborFrame.maxY,
                           originalDraggedFrame.minY, originalDraggedFrame.maxY) else { return nil }
            let newWidth = max(minNeighborDimension, neighborFrame.maxX - move.newPosition)
            let newMinX = neighborFrame.maxX - newWidth
            return CGRect(x: newMinX, y: neighborFrame.minY, width: newWidth, height: neighborFrame.height)

        case .left:
            // Dragged window's left edge moved; a neighbor to its left whose
            // right edge matched keeps its own left edge fixed.
            guard abs(neighborFrame.maxX - move.oldPosition) <= tolerance,
                  overlaps(neighborFrame.minY, neighborFrame.maxY,
                           originalDraggedFrame.minY, originalDraggedFrame.maxY) else { return nil }
            let newWidth = max(minNeighborDimension, move.newPosition - neighborFrame.minX)
            return CGRect(x: neighborFrame.minX, y: neighborFrame.minY, width: newWidth, height: neighborFrame.height)

        case .bottom:
            // Dragged window's bottom edge (maxY) moved; a neighbor below
            // whose top edge matched keeps its own bottom edge fixed.
            guard abs(neighborFrame.minY - move.oldPosition) <= tolerance,
                  overlaps(neighborFrame.minX, neighborFrame.maxX,
                           originalDraggedFrame.minX, originalDraggedFrame.maxX) else { return nil }
            let newHeight = max(minNeighborDimension, neighborFrame.maxY - move.newPosition)
            let newMinY = neighborFrame.maxY - newHeight
            return CGRect(x: neighborFrame.minX, y: newMinY, width: neighborFrame.width, height: newHeight)

        case .top:
            // Dragged window's top edge (minY) moved; a neighbor above whose
            // bottom edge matched keeps its own top edge fixed.
            guard abs(neighborFrame.maxY - move.oldPosition) <= tolerance,
                  overlaps(neighborFrame.minX, neighborFrame.maxX,
                           originalDraggedFrame.minX, originalDraggedFrame.maxX) else { return nil }
            let newHeight = max(minNeighborDimension, move.newPosition - neighborFrame.minY)
            return CGRect(x: neighborFrame.minX, y: neighborFrame.minY, width: neighborFrame.width, height: newHeight)
        }
    }

    private static func overlaps(_ aMin: CGFloat, _ aMax: CGFloat, _ bMin: CGFloat, _ bMax: CGFloat) -> Bool {
        aMin < bMax && aMax > bMin
    }
}
