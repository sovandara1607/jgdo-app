import XCTest
@testable import JgDo

/// `WindowMagnetismEngine` is pure CG geometry (no AppKit/AX), so it's
/// fully unit-testable the same way `SnapEngine`/`CoordinateSpace` are —
/// exact synthetic rects, no live windows or screens involved.
final class WindowMagnetismEngineTests: XCTestCase {

    // A 1000×1000 screen, arbitrary but fixed.
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let gap: CGFloat = 8
    let distance: CGFloat = 12

    // MARK: - Move: screen edges

    func testMoveSnapsToLeftScreenEdge() {
        // Window sitting 5pt from the left edge — within the 12pt distance.
        let frame = CGRect(x: 5, y: 100, width: 200, height: 200)
        let origin = WindowMagnetismEngine.snappedOrigin(
            for: frame, candidates: [], screenBounds: screen, distance: distance, gap: gap
        )
        XCTAssertEqual(origin?.x, screen.minX + gap) // 8
        XCTAssertEqual(origin?.y, frame.minY, "Y axis had no nearby candidate, so it must stay put")
    }

    func testMoveSnapsToRightScreenEdge() {
        let width: CGFloat = 200
        // maxX should land near screen.maxX - gap when close enough.
        let frame = CGRect(x: 780, y: 100, width: width, height: 200) // maxX = 980, target minX = 1000-200-8=792
        let origin = WindowMagnetismEngine.snappedOrigin(
            for: frame, candidates: [], screenBounds: screen, distance: distance, gap: gap
        )
        XCTAssertEqual(origin?.x, screen.maxX - width - gap)
    }

    func testMoveDoesNotSnapWhenFarFromEverything() {
        let frame = CGRect(x: 400, y: 400, width: 100, height: 100)
        let origin = WindowMagnetismEngine.snappedOrigin(
            for: frame, candidates: [], screenBounds: screen, distance: distance, gap: gap
        )
        XCTAssertNil(origin)
    }

    func testZeroDistanceDisablesSnapping() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100) // exactly at the screen origin
        let origin = WindowMagnetismEngine.snappedOrigin(
            for: frame, candidates: [], screenBounds: screen, distance: 0, gap: gap
        )
        XCTAssertNil(origin, "distance <= 0 must disable magnetism entirely")
    }

    // MARK: - Move: window-to-window

    func testMoveSnapsFlushToNeighborsRightEdge() {
        let neighbor = CGRect(x: 100, y: 100, width: 200, height: 200) // maxX = 300
        // Dragged window's left edge approaches the neighbor's right edge + gap.
        let frame = CGRect(x: 305, y: 150, width: 150, height: 150)
        let origin = WindowMagnetismEngine.snappedOrigin(
            for: frame, candidates: [neighbor], screenBounds: screen, distance: distance, gap: gap
        )
        XCTAssertEqual(origin?.x, neighbor.maxX + gap) // 308
    }

    func testMoveSnapsAlignedWithNeighborsLeftEdge() {
        let neighbor = CGRect(x: 100, y: 100, width: 200, height: 200) // Y span 100...300
        // Dragged window's left edge nearly matches the neighbor's left edge
        // (X-aligned, not touching) — Y span (150...300) overlaps the
        // neighbor's, so it qualifies as a magnet source.
        let frame = CGRect(x: 105, y: 150, width: 150, height: 150)
        let origin = WindowMagnetismEngine.snappedOrigin(
            for: frame, candidates: [neighbor], screenBounds: screen, distance: distance, gap: gap
        )
        XCTAssertEqual(origin?.x, neighbor.minX) // 100
    }

    func testMoveIgnoresNeighborWithNoVerticalOverlap() {
        // The neighbor's X-aligned position (100) would be well within
        // `distance` of frame.minX (105) if vertical overlap weren't
        // required — but their Y spans (0...50 vs 500...550) don't
        // overlap, so it must be excluded from X-axis candidacy entirely.
        let neighbor = CGRect(x: 100, y: 500, width: 50, height: 50)
        let frame = CGRect(x: 105, y: 0, width: 50, height: 50)
        let origin = WindowMagnetismEngine.snappedOrigin(
            for: frame, candidates: [neighbor], screenBounds: screen, distance: distance, gap: gap
        )
        // X axis: no valid candidate (neighbor excluded, screen edges far) → unchanged.
        XCTAssertEqual(origin?.x, frame.minX)
        // Y axis is free to snap independently — frame.minY=0 is within
        // range of the screen's own top edge (unrelated to the neighbor).
        XCTAssertEqual(origin?.y, screen.minY + gap)
    }

    func testMovePicksClosestCandidateWhenMultipleAreInRange() {
        // Two candidates both within distance of the dragged window's left
        // edge — the closer one must win.
        let near = CGRect(x: 100, y: 100, width: 100, height: 100)   // aligned candidate at x=100, target minX=100
        let far = CGRect(x: 90, y: 100, width: 5, height: 100)        // flush candidate at x = 95+8=103
        let frame = CGRect(x: 101, y: 120, width: 50, height: 50)     // closest to x=100
        let origin = WindowMagnetismEngine.snappedOrigin(
            for: frame, candidates: [near, far], screenBounds: screen, distance: distance, gap: gap
        )
        XCTAssertEqual(origin?.x, 100)
    }

    // MARK: - Resize: single edge

    func testResizeLeftEdgeSnapsToScreenBound() {
        let frame = CGRect(x: 6, y: 100, width: 200, height: 200)
        let snapped = WindowMagnetismEngine.snappedEdge(
            .left, frame: frame, candidates: [], screenBounds: screen, distance: distance, gap: gap
        )
        XCTAssertEqual(snapped, screen.minX + gap)
    }

    func testResizeRightEdgeSnapsToNeighborsLeftEdge() {
        let neighbor = CGRect(x: 500, y: 0, width: 200, height: 1000)
        // Dragged window's right edge approaches the neighbor's left edge, minus gap.
        let frame = CGRect(x: 100, y: 100, width: 388, height: 200) // maxX = 488, target = 500-8=492
        let snapped = WindowMagnetismEngine.snappedEdge(
            .right, frame: frame, candidates: [neighbor], screenBounds: screen, distance: distance, gap: gap
        )
        XCTAssertEqual(snapped, neighbor.minX - gap)
    }

    func testResizeTopEdgeSnapsToNeighborsBottomEdge() {
        let neighbor = CGRect(x: 0, y: 0, width: 1000, height: 200) // maxY = 200
        let frame = CGRect(x: 100, y: 205, width: 200, height: 300) // minY near neighbor.maxY + gap = 208
        let snapped = WindowMagnetismEngine.snappedEdge(
            .top, frame: frame, candidates: [neighbor], screenBounds: screen, distance: distance, gap: gap
        )
        XCTAssertEqual(snapped, neighbor.maxY + gap)
    }

    func testResizeReturnsNilWhenNothingInRange() {
        let frame = CGRect(x: 400, y: 400, width: 100, height: 100)
        let snapped = WindowMagnetismEngine.snappedEdge(
            .bottom, frame: frame, candidates: [], screenBounds: screen, distance: distance, gap: gap
        )
        XCTAssertNil(snapped)
    }

    // MARK: - Equal-size nudge

    func testMatchingDimensionFindsCloseButNotIdenticalWidth() {
        let a = CGRect(x: 0, y: 0, width: 300, height: 200)
        let b = CGRect(x: 0, y: 0, width: 305, height: 400)
        let matched = WindowMagnetismEngine.matchingDimension(of: a, candidates: [b], tolerance: 10, horizontal: true)
        XCTAssertEqual(matched, 305)
    }

    func testMatchingDimensionIgnoresAlreadyEqualWidths() {
        let a = CGRect(x: 0, y: 0, width: 300, height: 200)
        let b = CGRect(x: 0, y: 0, width: 300, height: 400)
        let matched = WindowMagnetismEngine.matchingDimension(of: a, candidates: [b], tolerance: 10, horizontal: true)
        XCTAssertNil(matched, "already-equal widths need no nudge")
    }

    func testMatchingDimensionIgnoresFarApartWidths() {
        let a = CGRect(x: 0, y: 0, width: 300, height: 200)
        let b = CGRect(x: 0, y: 0, width: 500, height: 400)
        let matched = WindowMagnetismEngine.matchingDimension(of: a, candidates: [b], tolerance: 10, horizontal: true)
        XCTAssertNil(matched)
    }

    func testMatchingDimensionChecksHeightIndependentlyOfWidth() {
        let a = CGRect(x: 0, y: 0, width: 300, height: 200)
        let b = CGRect(x: 0, y: 0, width: 900, height: 204)
        let matched = WindowMagnetismEngine.matchingDimension(of: a, candidates: [b], tolerance: 10, horizontal: false)
        XCTAssertEqual(matched, 204)
    }
}
