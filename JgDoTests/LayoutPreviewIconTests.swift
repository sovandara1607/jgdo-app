import XCTest
@testable import JgDo

/// `LayoutPreviewIcon.fraction(for:)` is pure geometry — no SwiftUI
/// rendering needed to verify every `WindowLayout` case maps to a sane,
/// in-bounds highlighted region.
final class LayoutPreviewIconTests: XCTestCase {

    func testEveryLayoutStaysWithinTheOuterBox() {
        for layout in WindowLayout.allCases {
            let f = LayoutPreviewIcon.fraction(for: layout)
            XCTAssertGreaterThanOrEqual(f.x, 0, "\(layout) x")
            XCTAssertGreaterThanOrEqual(f.y, 0, "\(layout) y")
            XCTAssertLessThanOrEqual(f.x + f.width, 1.001, "\(layout) right edge")
            XCTAssertLessThanOrEqual(f.y + f.height, 1.001, "\(layout) bottom edge")
            XCTAssertGreaterThan(f.width, 0, "\(layout) width")
            XCTAssertGreaterThan(f.height, 0, "\(layout) height")
        }
    }

    func testHalvesCoverExactlyHalfTheArea() {
        for layout: WindowLayout in [.leftHalf, .rightHalf, .topHalf, .bottomHalf] {
            let f = LayoutPreviewIcon.fraction(for: layout)
            XCTAssertEqual(f.width * f.height, 0.5, accuracy: 0.001, "\(layout) area")
        }
    }

    func testCornersCoverExactlyOneQuarter() {
        for layout: WindowLayout in [.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let f = LayoutPreviewIcon.fraction(for: layout)
            XCTAssertEqual(f.width * f.height, 0.25, accuracy: 0.001, "\(layout) area")
        }
    }

    func testLeftHalfIsFlushToTheLeftEdge() {
        XCTAssertEqual(LayoutPreviewIcon.fraction(for: .leftHalf).x, 0)
    }

    func testRightHalfIsFlushToTheRightEdge() {
        let f = LayoutPreviewIcon.fraction(for: .rightHalf)
        XCTAssertEqual(f.x + f.width, 1, accuracy: 0.001)
    }

    func testMaximizeCoversNearlyTheWholeBox() {
        let f = LayoutPreviewIcon.fraction(for: .maximize)
        XCTAssertGreaterThan(f.width * f.height, 0.7)
    }

    func testCenterIsSmallerThanMaximizeAndNotFlushToAnyEdge() {
        let center = LayoutPreviewIcon.fraction(for: .center)
        let maximize = LayoutPreviewIcon.fraction(for: .maximize)
        XCTAssertLessThan(center.width * center.height, maximize.width * maximize.height)
        XCTAssertGreaterThan(center.x, 0)
        XCTAssertGreaterThan(center.y, 0)
    }
}
