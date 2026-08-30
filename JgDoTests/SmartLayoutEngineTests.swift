import XCTest
@testable import JgDo

/// `SmartLayoutEngine.detectSignature` is pure statistics over plain
/// (bundleID, timestamp) tuples — no SwiftData, no live windows, no
/// `NSWorkspace` — so it's fully unit-testable with synthetic fixture
/// events, the same way `WindowMagnetismEngine`'s pure geometry is. The
/// SwiftData-backed recording/suggestion-lifecycle side of the engine
/// isn't covered here (not test-environment-safe per the plan's own
/// testing-scope decision) — this file only exercises the detection rule.
final class SmartLayoutEngineTests: XCTestCase {

    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let window: TimeInterval = 240
    let appCountRange = 2...4
    let minSwitches = 3

    private func events(_ pairs: [(String, TimeInterval)]) -> [(bundleID: String, timestamp: Date)] {
        pairs.map { (bundleID: $0.0, timestamp: now.addingTimeInterval($0.1)) }
    }

    // MARK: - Positive cases

    func testDetectsSignatureForQualifyingTwoAppSession() {
        // 4 switches between the same two apps, all inside the window.
        let evts = events([
            ("com.a", -200), ("com.b", -150), ("com.a", -100), ("com.b", -50), ("com.a", -10),
        ])
        let sig = SmartLayoutEngine.detectSignature(
            from: evts, now: now, windowSeconds: window,
            appCountRange: appCountRange, minSwitches: minSwitches)
        XCTAssertEqual(sig, "com.a|com.b")
    }

    func testSignatureIsSortedRegardlessOfActivationOrder() {
        let evts = events([
            ("com.z", -200), ("com.a", -150), ("com.z", -100), ("com.a", -50),
        ])
        let sig = SmartLayoutEngine.detectSignature(
            from: evts, now: now, windowSeconds: window,
            appCountRange: appCountRange, minSwitches: minSwitches)
        XCTAssertEqual(sig, "com.a|com.z")
    }

    func testDetectsThreeAppSignatureWithinRange() {
        let evts = events([
            ("com.a", -200), ("com.b", -160), ("com.c", -120), ("com.a", -80),
        ])
        let sig = SmartLayoutEngine.detectSignature(
            from: evts, now: now, windowSeconds: window,
            appCountRange: appCountRange, minSwitches: minSwitches)
        XCTAssertEqual(sig, "com.a|com.b|com.c")
    }

    // MARK: - Negative cases

    func testRejectsSingleAppNoRealSwitching() {
        // Same app "activated" repeatedly isn't a combination at all.
        let evts = events([("com.a", -200), ("com.a", -150), ("com.a", -100), ("com.a", -50)])
        let sig = SmartLayoutEngine.detectSignature(
            from: evts, now: now, windowSeconds: window,
            appCountRange: appCountRange, minSwitches: minSwitches)
        XCTAssertNil(sig)
    }

    func testRejectsTooFewSwitches() {
        // Only 2 switches (3 events) — below minSwitches of 3.
        let evts = events([("com.a", -100), ("com.b", -50), ("com.a", -10)])
        let sig = SmartLayoutEngine.detectSignature(
            from: evts, now: now, windowSeconds: window,
            appCountRange: appCountRange, minSwitches: minSwitches)
        XCTAssertNil(sig)
    }

    func testRejectsTooManyDistinctApps() {
        // 5 distinct apps — above the appCountRange upper bound of 4,
        // more likely to be a busy unrelated stretch than one workflow.
        let evts = events([
            ("com.a", -200), ("com.b", -180), ("com.c", -160),
            ("com.d", -140), ("com.e", -120), ("com.a", -100),
        ])
        let sig = SmartLayoutEngine.detectSignature(
            from: evts, now: now, windowSeconds: window,
            appCountRange: appCountRange, minSwitches: minSwitches)
        XCTAssertNil(sig)
    }

    func testIgnoresEventsOutsideTheRollingWindow() {
        // Two of these four events are older than the 240s window — only
        // 2 fall inside it, which isn't enough switches.
        let evts = events([
            ("com.a", -500), ("com.b", -400), // outside window
            ("com.a", -100), ("com.b", -50),  // inside window
        ])
        let sig = SmartLayoutEngine.detectSignature(
            from: evts, now: now, windowSeconds: window,
            appCountRange: appCountRange, minSwitches: minSwitches)
        XCTAssertNil(sig)
    }

    func testIgnoresEventsAfterNow() {
        // A future-timestamped event (clock skew / bad input) shouldn't
        // count toward the window.
        let evts = events([
            ("com.a", -100), ("com.b", -50), ("com.a", -10), ("com.b", 50),
        ])
        let sig = SmartLayoutEngine.detectSignature(
            from: evts, now: now, windowSeconds: window,
            appCountRange: appCountRange, minSwitches: minSwitches)
        // Only 3 events (-100, -50, -10) qualify → 2 switches → below minSwitches.
        XCTAssertNil(sig)
    }

    func testEmptyEventsProducesNoSignature() {
        let sig = SmartLayoutEngine.detectSignature(
            from: [], now: now, windowSeconds: window,
            appCountRange: appCountRange, minSwitches: minSwitches)
        XCTAssertNil(sig)
    }
}
