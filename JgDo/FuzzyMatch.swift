import Foundation

/// Lightweight fuzzy subsequence matcher (VSCode/Sublime-style): every
/// character of `query` must appear in `target`, in order, but not
/// necessarily contiguously. Scored so tighter, earlier, word-start matches
/// rank higher than scattered ones. No third-party dependency.
enum FuzzyMatch {

    /// Returns a score > 0 if `query` fuzzy-matches `target`, nil otherwise.
    /// Higher is a better match. Empty `query` always matches with score 0.
    static func score(query: String, target: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let q = Array(query.lowercased())
        let t = Array(target.lowercased())
        guard !t.isEmpty else { return nil }

        var qi = 0
        var score = 0
        var previousMatchIndex = -1
        var runLength = 0

        for (ti, ch) in t.enumerated() {
            guard qi < q.count else { break }
            guard ch == q[qi] else { continue }

            if previousMatchIndex == ti - 1 {
                runLength += 1
                score += 6 * runLength   // contiguous runs score increasingly higher
            } else {
                runLength = 1
                score += 2
            }
            if ti == 0 || t[ti - 1] == " " || t[ti - 1] == "-" || t[ti - 1] == "_" {
                score += 8   // word-start bonus
            }
            previousMatchIndex = ti
            qi += 1
        }

        guard qi == q.count else { return nil }
        // Earlier overall match position is slightly preferred.
        score -= previousMatchIndex / 4
        return score
    }

    /// Best score across several candidate strings (e.g. app name + window title).
    static func bestScore(query: String, targets: [String]) -> Int? {
        targets.compactMap { score(query: query, target: $0) }.max()
    }
}
