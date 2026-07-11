import AppKit

/// Drives the searchable "which window to align next to" list shown during
/// every ⌘-drag (Feature 1's move mode). By default the selection auto-
/// tracks whichever candidate is nearest the cursor — the same inference the
/// drag used before this list existed — so a plain drag-and-release still
/// works with zero keyboard interaction. Typing or pressing Tab/arrows pins
/// an explicit choice for the rest of the gesture.
@Observable
final class DragTargetPickerState {
    struct Candidate: Identifiable {
        let windowID: CGWindowID
        let pid: pid_t
        let appName: String
        let title: String
        let bounds: CGRect
        var id: CGWindowID { windowID }
    }

    private(set) var candidates: [Candidate] = []
    var searchText: String = ""
    private(set) var selectedIndex: Int = 0
    /// True once the user has typed or pressed Tab/an arrow — after that,
    /// the selection stops auto-following the cursor for the rest of the drag.
    private(set) var userDidInteract = false

    var filtered: [Candidate] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return candidates }
        return candidates
            .compactMap { c -> (Candidate, Int)? in
                guard let s = FuzzyMatch.bestScore(query: q, targets: [c.appName, c.title]) else { return nil }
                return (c, s)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var selectedCandidate: Candidate? {
        let f = filtered
        guard f.indices.contains(selectedIndex) else { return f.first }
        return f[selectedIndex]
    }

    func reset() {
        candidates = []
        searchText = ""
        selectedIndex = 0
        userDidInteract = false
    }

    /// Replaces the candidate list — called once per drag gesture, since the
    /// window set doesn't change mid-drag in practice.
    func setCandidates(_ new: [Candidate]) {
        candidates = new
    }

    /// Re-sorts by distance to `point` and selects the nearest. No-op once
    /// the user has explicitly interacted, so their choice sticks.
    func autoSelectNearest(to point: CGPoint) {
        guard !userDidInteract, !candidates.isEmpty else { return }
        candidates.sort { distance($0.bounds.center, point) < distance($1.bounds.center, point) }
        selectedIndex = 0
    }

    func moveSelection(_ delta: Int) {
        userDidInteract = true
        let f = filtered
        guard !f.isEmpty else { return }
        selectedIndex = ((selectedIndex % f.count) + delta + f.count) % f.count
    }

    func appendSearchText(_ s: String) {
        userDidInteract = true
        searchText += s
        selectedIndex = 0
    }

    func backspaceSearch() {
        guard !searchText.isEmpty else { return }
        userDidInteract = true
        searchText.removeLast()
        selectedIndex = 0
    }
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = a.x - b.x, dy = a.y - b.y
    return (dx * dx + dy * dy).squareRoot()
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
