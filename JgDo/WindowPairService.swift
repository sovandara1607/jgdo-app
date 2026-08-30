import Foundation
import SwiftData

/// Locally-remembered "these two apps get paired often" signal — no AI,
/// just a simple frequency + recency score per unordered app-bundle pair.
/// Powers `WindowPartnerRanking`'s "previously paired window" tier: if you
/// keep pairing VS Code with Safari, snapping VS Code increasingly prefers
/// Safari for the other side.
@MainActor
final class WindowPairService {
    static let shared = WindowPairService()

    private let persistence: PersistenceProviding

    /// `persistence` defaults to the real on-disk store — only tests pass
    /// something else. See `WorkspaceService.init` for why this is `nil`
    /// rather than defaulting straight to `Persistence.shared`.
    init(persistence: PersistenceProviding? = nil) {
        self.persistence = persistence ?? Persistence.shared
    }

    /// Call after a dual-snap actually applies — auto-picked or explicitly
    /// chosen via the ⌃⌥⇥ search — so this pair is reinforced for next
    /// time. No-ops if either bundle ID is missing or they're the same app.
    func record(_ bundleIDA: String?, _ bundleIDB: String?) {
        guard let a = bundleIDA, let b = bundleIDB, a != b else { return }
        let (lo, hi) = a < b ? (a, b) : (b, a)
        let ctx = persistence.context
        let existing = ctx.fetchLogged(FetchDescriptor<WindowPairScore>(
            predicate: #Predicate { $0.bundleIDA == lo && $0.bundleIDB == hi }), using: AppLog.workspace).first
        if let existing {
            existing.pairCount += 1
            existing.lastPairedAt = Date()
        } else {
            ctx.insert(WindowPairScore(bundleIDA: lo, bundleIDB: hi))
        }
        persistence.save()
    }

    /// A small score (0 if this pair has never been recorded) for how
    /// strongly `bundleID` and `candidate` have been paired before —
    /// frequency with a recency decay so an old one-off pairing doesn't
    /// outrank a fresh habit. Capped low enough that same-display/recency
    /// signals in `WindowPartnerRanking` can still win on their own; this
    /// is a nudge toward a known habit, not an override of everything else.
    func score(_ bundleID: String?, _ candidate: String?) -> Double {
        guard let a = bundleID, let b = candidate, a != b else { return 0 }
        let (lo, hi) = a < b ? (a, b) : (b, a)
        let ctx = persistence.context
        guard let row = ctx.fetchLogged(FetchDescriptor<WindowPairScore>(
            predicate: #Predicate { $0.bundleIDA == lo && $0.bundleIDB == hi }), using: AppLog.workspace).first
        else { return 0 }
        let days = max(Date().timeIntervalSince(row.lastPairedAt) / 86400, 0)
        let recencyDecay = max(1 - days / 30, 0.15)   // fades over ~30 days, never to zero
        return min(Double(row.pairCount), 20) * recencyDecay
    }
}
