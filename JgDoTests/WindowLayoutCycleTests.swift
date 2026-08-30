import XCTest
@testable import JgDo

/// `LayoutCycleFamily`/`LayoutCycleStep` are pure geometry/ordering — the
/// ⌃⌥←/→ overlay's step list and its wrap-around index math, with no
/// AppKit/AX dependency, verified the same way `LayoutPreviewIconTests`
/// verifies its own pure geometry.
final class WindowLayoutCycleTests: XCTestCase {

    func testLeftFamilyHasSixSteps() {
        XCTAssertEqual(LayoutCycleFamily.left.steps.count, 6)
    }

    func testRightFamilyMirrorsLeftInCount() {
        XCTAssertEqual(LayoutCycleFamily.left.steps.count, LayoutCycleFamily.right.steps.count)
    }

    func testFirstStepIsThePlainHalfAtOneHalf() {
        guard case .layout(let layout, let fraction) = LayoutCycleFamily.left.steps[0].kind else {
            return XCTFail("expected .layout")
        }
        XCTAssertEqual(layout, .leftHalf)
        XCTAssertEqual(fraction, 0.5)
    }

    func testLastStepIsPreviousDisplayForLeftFamily() {
        XCTAssertEqual(LayoutCycleFamily.left.steps.last?.kind, .previousDisplay)
    }

    func testLastStepIsNextDisplayForRightFamily() {
        XCTAssertEqual(LayoutCycleFamily.right.steps.last?.kind, .nextDisplay)
    }

    func testSteppedIndexAdvancesForward() {
        XCTAssertEqual(LayoutCycleFamily.steppedIndex(0, delta: 1, count: 6), 1)
    }

    func testSteppedIndexWrapsForwardPastEnd() {
        XCTAssertEqual(LayoutCycleFamily.steppedIndex(5, delta: 1, count: 6), 0)
    }

    func testSteppedIndexWrapsBackwardPastStart() {
        XCTAssertEqual(LayoutCycleFamily.steppedIndex(0, delta: -1, count: 6), 5)
    }

    func testSteppedIndexHandlesZeroCountWithoutCrashing() {
        XCTAssertEqual(LayoutCycleFamily.steppedIndex(0, delta: 1, count: 0), 0)
    }

    func testQuarterStepsUseTopAndBottomLeftForLeftFamily() {
        let steps = LayoutCycleFamily.left.steps
        guard case .layout(let top, _) = steps[3].kind, case .layout(let bottom, _) = steps[4].kind else {
            return XCTFail("expected .layout steps")
        }
        XCTAssertEqual(top, .topLeft)
        XCTAssertEqual(bottom, .bottomLeft)
    }

    func testQuarterStepsUseTopAndBottomRightForRightFamily() {
        let steps = LayoutCycleFamily.right.steps
        guard case .layout(let top, _) = steps[3].kind, case .layout(let bottom, _) = steps[4].kind else {
            return XCTFail("expected .layout steps")
        }
        XCTAssertEqual(top, .topRight)
        XCTAssertEqual(bottom, .bottomRight)
    }
}
