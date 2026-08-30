import Foundation

/// Collects what happened during one `WorkspaceService.restore(_:)` call —
/// which apps' windows were placed, and why any weren't — so a restore
/// that only partially succeeds is reported to the user instead of some
/// windows just silently failing to reappear (the previous behavior:
/// missing apps, unmatched windows, and AX lookup failures were all
/// swallowed with no user-visible trace).
final class RestoreDiagnostics {
    enum Outcome {
        /// `matched` may be less than `total` if there were fewer live
        /// windows than saved placements (still counts as "placed" — it's
        /// a partial success, not a failure — but is called out below).
        case placed(app: String, matched: Int, total: Int)
        case appNotInstalled(app: String)
        case appProducedNoWindows(app: String)
    }

    private(set) var outcomes: [Outcome] = []

    func record(_ outcome: Outcome) {
        outcomes.append(outcome)
    }

    /// True if anything didn't fully succeed — drives whether the UI
    /// bothers interrupting the user at all (a clean restore stays silent).
    var hasIssues: Bool {
        outcomes.contains {
            switch $0 {
            case .placed(_, let matched, let total): return matched < total
            case .appNotInstalled, .appProducedNoWindows: return true
            }
        }
    }

    /// e.g. "2 of 3 apps restored — Slack not installed; Mail opened no windows."
    var summary: String {
        let totalApps = outcomes.count
        let fullyPlaced = outcomes.filter {
            if case .placed(_, let matched, let total) = $0 { return matched == total }
            return false
        }.count
        var line = "\(fullyPlaced) of \(totalApps) app\(totalApps == 1 ? "" : "s") fully restored"

        let issues = outcomes.compactMap { outcome -> String? in
            switch outcome {
            case .placed(let app, let matched, let total) where matched < total:
                return "\(app): \(matched) of \(total) windows"
            case .placed:
                return nil
            case .appNotInstalled(let app):
                return "\(app) not installed"
            case .appProducedNoWindows(let app):
                return "\(app) opened no windows"
            }
        }
        if !issues.isEmpty {
            line += " — " + issues.joined(separator: "; ")
        }
        return line
    }
}
