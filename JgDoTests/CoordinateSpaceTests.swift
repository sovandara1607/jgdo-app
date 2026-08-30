import XCTest
@testable import JgDo

/// `CoordinateSpace` centralizes the one CG(top-left)⇄AppKit(bottom-left)
/// flip every window-placement call site needs. These tests pin the
/// formula against hand-computed values (not live `NSScreen.screens`,
/// which may be absent/singular in CI) via the `primaryHeight` parameter,
/// so they're deterministic regardless of the host's actual monitor setup.
final class CoordinateSpaceTests: XCTestCase {

    // A primary display 1000pt tall — arbitrary but fixed for these tests.
    let primaryHeight: CGFloat = 1000

    // MARK: Rects

    func testAppKitFromCGRoundTrip() {
        // A window whose CG top-left origin is (100, 50), 300x200.
        let cg = CGRect(x: 100, y: 50, width: 300, height: 200)
        let appKit = CoordinateSpace.appKit(fromCG: cg, primaryHeight: primaryHeight)

        // Top edge (CG y=50) is 950pt above the bottom of a 1000pt-tall
        // primary screen once flipped, and the AppKit rect's origin is its
        // BOTTOM-left corner, so appKit.minY = primaryHeight - cg.maxY.
        XCTAssertEqual(appKit.minX, 100)
        XCTAssertEqual(appKit.minY, 1000 - 250) // primaryHeight - cg.maxY
        XCTAssertEqual(appKit.width, 300)
        XCTAssertEqual(appKit.height, 200)

        let back = CoordinateSpace.cg(fromAppKit: appKit, primaryHeight: primaryHeight)
        XCTAssertEqual(back, cg, "the flip must be its own inverse")
    }

    func testCgFromAppKitMatchesHandComputedValue() {
        // A window sitting flush against the bottom of the primary screen,
        // 400x300, in AppKit space.
        let appKit = CGRect(x: 0, y: 0, width: 400, height: 300)
        let cg = CoordinateSpace.cg(fromAppKit: appKit, primaryHeight: primaryHeight)
        // Its CG top-left y should be primaryHeight - height = 700.
        XCTAssertEqual(cg.origin, CGPoint(x: 0, y: 700))
        XCTAssertEqual(cg.size, appKit.size)
    }

    // MARK: Points

    func testPointRoundTrip() {
        let cgPoint = CGPoint(x: 42, y: 88)
        let appKitPoint = CoordinateSpace.appKit(fromCG: cgPoint, primaryHeight: primaryHeight)
        XCTAssertEqual(appKitPoint, CGPoint(x: 42, y: primaryHeight - 88))
        let back = CoordinateSpace.cg(fromAppKit: appKitPoint, primaryHeight: primaryHeight)
        XCTAssertEqual(back, cgPoint)
    }

    // MARK: Regression — WorkspaceService's fixed operator-precedence bug
    //
    // The old inline code was:
    //   NSScreen.screens.first?.frame.height ?? 0 - info.bounds.maxY
    // which — because `??` binds looser than `-` — parsed as
    //   NSScreen.screens.first?.frame.height ?? (0 - info.bounds.maxY)
    // i.e. it silently ignored the real primary height whenever the
    // optional was non-nil in the wrong way conceptually, and produced a
    // *negative* fallback in the edge case where it WAS nil. This test
    // pins the correct value (a plain subtraction, no such precedence
    // trap) for the same shape of input that exposed it.
    func testWorkspaceRestorationBugRegression() {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 400) // maxY = 420
        let appKit = CoordinateSpace.appKit(fromCG: bounds, primaryHeight: primaryHeight)
        XCTAssertEqual(appKit.minY, primaryHeight - bounds.maxY) // 1000 - 420 = 580
        XCTAssertNotEqual(appKit.minY, 0 - bounds.maxY, "must never fall back to the old precedence-bug value")
    }

    // MARK: Screen lookup

    func testScreenContainingPointReturnsNilOnlyWithZeroScreens() {
        // Can't fabricate fake NSScreen instances (no public initializer),
        // so this exercises the real fallback chain against the live
        // display config, which always has at least one screen while
        // tests run — asserting the "some screen is always returned"
        // guarantee the fallback chain (`.first{contains} ?? .main ??
        // .screens.first`) exists to provide.
        let farAwayPoint = CGPoint(x: -1_000_000, y: -1_000_000)
        // Even a point no real screen contains should still resolve via
        // the `.main ?? .screens.first` fallback, not return nil.
        XCTAssertNotNil(CoordinateSpace.screen(containing: farAwayPoint))
    }

    func testPrimaryScreenHeightIsNonNegative() {
        // Sanity check on the live value the default-parameter path uses.
        XCTAssertGreaterThanOrEqual(CoordinateSpace.primaryScreenHeight, 0)
    }
}
