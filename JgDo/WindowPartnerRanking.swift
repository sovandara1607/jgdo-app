import Foundation

/// Chooses which OTHER open window a dual-snap (⌃⌥←/→'s auto-fill, and
/// every other layout hotkey's own dual-snap) should pair with the primary
/// window — see `WindowCandidateSelector`, the one place that builds
/// `Candidate`s and calls this. Replaces the old "just grab the topmost
/// other visible window" heuristic with a ranked pick, in priority order:
///
///  1. Previously paired with this app (`WindowPairService`) — the
///     dominant tier once a habit is actually established; a single
///     one-off pairing only nudges, it doesn't override everything else.
///  2. Same display as the primary window.
///  3. Recency (most recently focused/used) — `HUDState.recentApps` order.
///  4. Front-to-back order, as a tiebreaker only.
///
/// "Same active Space" and "currently visible" from the product spec are
/// intentionally not separate scoring terms: `WindowCandidateSelector`
/// only ever considers windows `CGWindowListCopyWindowInfo`'s
/// `.optionOnScreenOnly` already returned, which — absent a reliable
/// public per-window Space API — is the same signal both of those terms
/// are trying to capture. Modeling it twice would just double-count it.
///
/// Pure and unit-testable on purpose: everything here is plain data,
/// pre-filtered by `WindowCandidateSelector`'s eligibility checks — no
/// live window/AX access in this file.
enum WindowPartnerRanking {

    /// One eligible candidate.
    struct Candidate: Equatable {
        let pid: pid_t
        let bundleID: String?
        /// Position in the recent-apps list (0 = most recently activated),
        /// nil if the app hasn't been activated recently at all.
        let recencyRank: Int?
        let isOnSameScreen: Bool
        /// Raw pairing strength from `WindowPairService.score` (frequency
        /// capped, decayed by recency) — `Weights.pairHistory` is what
        /// turns this into an actual score contribution.
        let pairScore: Double
        /// Original front-to-back position from `fetchWindows()` — the
        /// tiebreaker of last resort, so with zero other signal this
        /// reproduces the old "topmost visible window" behavior exactly.
        let frontToBackIndex: Int
    }

    /// Named so the relative importance of each tier is legible at a
    /// glance, and so retuning one doesn't require re-deriving the others.
    /// Deliberately NOT the illustrative numbers from the product spec —
    /// tuned so pairing history can outrank same-display only once it's a
    /// real, reinforced habit (a single pairing is a small nudge, not an
    /// override), matching this app's existing "silent, predictable, no
    /// surprises" design bar rather than a generic scoring template.
    enum Weights {
        /// Multiplies `WindowPairService.score`'s 0–20ish raw range up to
        /// a max around 80 — high enough to beat same-display + top
        /// recency combined (40 + 30 = 70) once a pairing is well
        /// established, but a single weak pairing (score ≈ 1) only adds
        /// ~4, nowhere near enough to override a better-placed candidate.
        static let pairHistory: Double = 4.0
        static let sameDisplay: Double = 40
        /// The most-recently-focused candidate (rank 0) gets the full
        /// bonus; it decays fast, since "focused two apps ago" shouldn't
        /// meaningfully outrank "on this display" or "no history at all."
        static let recencyMax: Double = 30
        /// Breaks ties only — small enough that it can never flip a
        /// decision any of the tiers above already made.
        static let frontToBackTiebreak: Double = 0.01
    }

    /// Named per-tier contributions for one candidate — what
    /// `WindowCandidateSelector`'s debug logging prints, and what `score`
    /// sums.
    struct ScoreBreakdown {
        let pairHistory: Double
        let sameDisplay: Double
        let recency: Double
        let tiebreak: Double
        var total: Double { pairHistory + sameDisplay + recency + tiebreak }
    }

    static func breakdown(_ c: Candidate) -> ScoreBreakdown {
        let recency = c.recencyRank.map { Weights.recencyMax / Double($0 + 1) } ?? 0
        return ScoreBreakdown(
            pairHistory: c.pairScore * Weights.pairHistory,
            sameDisplay: c.isOnSameScreen ? Weights.sameDisplay : 0,
            recency: recency,
            tiebreak: -Double(c.frontToBackIndex) * Weights.frontToBackTiebreak)
    }

    static func score(_ c: Candidate) -> Double { breakdown(c).total }

    /// The single best candidate, or nil for an empty list. First-occurrence
    /// wins ties (relevant only if two candidates score identically without
    /// the front-to-back tiebreak already having separated them).
    static func best(among candidates: [Candidate]) -> Candidate? {
        var winner: Candidate?
        var winnerScore = -Double.infinity
        for c in candidates {
            let s = score(c)
            if s > winnerScore {
                winner = c
                winnerScore = s
            }
        }
        return winner
    }
}
