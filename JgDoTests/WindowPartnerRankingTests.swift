import XCTest
@testable import JgDo

/// `WindowPartnerRanking` is pure scoring over plain data (no AX/live
/// windows), so it's fully unit-testable with synthetic candidates.
final class WindowPartnerRankingTests: XCTestCase {

    private func candidate(pid: pid_t, recencyRank: Int? = nil, sameScreen: Bool = false,
                            pairScore: Double = 0, frontToBackIndex: Int = 0) -> WindowPartnerRanking.Candidate {
        .init(pid: pid, bundleID: "com.example.\(pid)", recencyRank: recencyRank,
              isOnSameScreen: sameScreen, pairScore: pairScore, frontToBackIndex: frontToBackIndex)
    }

    func testEmptyListReturnsNil() {
        XCTAssertNil(WindowPartnerRanking.best(among: []))
    }

    func testWithNoSignalAtAllFallsBackToFrontToBackOrder() {
        // Nobody's recent, nobody's on the same screen, no pairing history —
        // the topmost (index 0) window should win, matching the old
        // "just grab the topmost visible window" heuristic.
        let topmost = candidate(pid: 1, frontToBackIndex: 0)
        let behind = candidate(pid: 2, frontToBackIndex: 1)
        XCTAssertEqual(WindowPartnerRanking.best(among: [topmost, behind])?.pid, 1)
    }

    func testMostRecentlyUsedBeatsFrontToBackOrder() {
        // Recently activated (rank 0) but further back on screen should
        // still win over a topmost window with no recency at all.
        let recentButBehind = candidate(pid: 1, recencyRank: 0, frontToBackIndex: 3)
        let topmostButStale = candidate(pid: 2, frontToBackIndex: 0)
        XCTAssertEqual(WindowPartnerRanking.best(among: [recentButBehind, topmostButStale])?.pid, 1)
    }

    func testSameScreenBeatsSlightlyMoreRecentOnAnotherScreen() {
        // A same-screen candidate should outrank one that's only slightly
        // more recent but on a different display — dual-snap shouldn't
        // reach across monitors when a same-screen option exists.
        let sameScreen = candidate(pid: 1, recencyRank: 2, sameScreen: true, frontToBackIndex: 2)
        let otherScreenSlightlyMoreRecent = candidate(pid: 2, recencyRank: 1, sameScreen: false, frontToBackIndex: 0)
        XCTAssertEqual(WindowPartnerRanking.best(among: [sameScreen, otherScreenSlightlyMoreRecent])?.pid, 1)
    }

    func testStrongPairingHistoryCanOutrankRecency() {
        // A window with no recency signal but a well-established pairing
        // history should be able to beat one that's merely recent.
        let stronglyPaired = candidate(pid: 1, pairScore: 20, frontToBackIndex: 3)
        let justRecent = candidate(pid: 2, recencyRank: 1, frontToBackIndex: 0)
        XCTAssertEqual(WindowPartnerRanking.best(among: [stronglyPaired, justRecent])?.pid, 1)
    }

    func testFrontToBackIndexOnlyBreaksTiesNeverDominates() {
        // Even a huge front-to-back gap shouldn't overcome an actual
        // recency/pairing signal — the tiebreak term is intentionally tiny.
        let farBehindButRecent = candidate(pid: 1, recencyRank: 0, frontToBackIndex: 50)
        let topmostWithNoSignal = candidate(pid: 2, frontToBackIndex: 0)
        XCTAssertEqual(WindowPartnerRanking.best(among: [farBehindButRecent, topmostWithNoSignal])?.pid, 1)
    }

    func testPreviouslyPairedAppReceivesPreferenceWhenOtherwiseEqual() {
        // Identical in every other respect — only the remembered pairing
        // history should decide it.
        let previouslyPaired = candidate(pid: 1, recencyRank: 3, sameScreen: true, pairScore: 1, frontToBackIndex: 1)
        let neverPaired = candidate(pid: 2, recencyRank: 3, sameScreen: true, pairScore: 0, frontToBackIndex: 1)
        XCTAssertEqual(WindowPartnerRanking.best(among: [previouslyPaired, neverPaired])?.pid, 1)
    }

    func testMostRecentCandidateWinsWhenOtherwiseEqual() {
        // Identical in every other respect — only recency should decide it.
        let moreRecent = candidate(pid: 1, recencyRank: 0, sameScreen: true, frontToBackIndex: 1)
        let lessRecent = candidate(pid: 2, recencyRank: 4, sameScreen: true, frontToBackIndex: 1)
        XCTAssertEqual(WindowPartnerRanking.best(among: [moreRecent, lessRecent])?.pid, 1)
    }

    func testCrossDisplayCandidateLosesToSuitableLocalCandidateEvenWithSomeRecencyDeficit() {
        // A local (same-display) candidate should win over a cross-display
        // one even when the cross-display one is somewhat more recent —
        // dual-snap shouldn't reach across monitors when a decent local
        // option exists.
        let local = candidate(pid: 1, recencyRank: 3, sameScreen: true, frontToBackIndex: 1)
        let crossDisplayMoreRecent = candidate(pid: 2, recencyRank: 0, sameScreen: false, frontToBackIndex: 0)
        XCTAssertEqual(WindowPartnerRanking.best(among: [local, crossDisplayMoreRecent])?.pid, 1)
    }

    func testWeakOneOffPairingDoesNotOverrideABetterPlacedCandidate() {
        // A single, weak pairing signal is a nudge, not an override — a
        // same-display candidate with no history at all should still win
        // over an off-screen-history match with only a token pairing score.
        let sameDisplayNoPairing = candidate(pid: 1, sameScreen: true, pairScore: 0, frontToBackIndex: 1)
        let weaklyPairedElsewhere = candidate(pid: 2, sameScreen: false, pairScore: 1, frontToBackIndex: 0)
        XCTAssertEqual(WindowPartnerRanking.best(among: [sameDisplayNoPairing, weaklyPairedElsewhere])?.pid, 1)
    }
}
