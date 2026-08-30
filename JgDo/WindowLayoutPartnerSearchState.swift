import AppKit

/// One row in the ⌃⌥←/→ overlay's Tab-triggered partner search — a window
/// that could fill the complementary half/third/quarter. One row per app
/// (its frontmost window), same granularity `resizeOtherVisibleWindow`
/// already uses for the old automatic pairing.
struct PartnerWindowCandidate: Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    let appName: String
    let icon: NSImage?

    /// Every open window other than `excludingPID`, one row per app — the
    /// same gathering logic used both by the interactive search
    /// (`WindowLayoutPartnerSearchState.reload`) and the layout overlay's
    /// own passive "Other Windows" preview, so the two can never disagree
    /// about what's actually open.
    static func others(excludingPID: pid_t) -> [PartnerWindowCandidate] {
        var seen = Set<pid_t>()
        var list: [PartnerWindowCandidate] = []
        for window in WindowManagerService().fetchWindows() where window.pid != excludingPID {
            guard !seen.contains(window.pid) else { continue }
            seen.insert(window.pid)
            list.append(PartnerWindowCandidate(pid: window.pid, appName: window.appName, icon: window.icon))
        }
        return list
    }
}

/// Backs `WindowLayoutPartnerSearchView`. Deliberately NOT built on
/// `CommandPaletteState` — that's a 3-tier groups→commands→files switcher
/// for a different job (find + focus any window); this is a single flat
/// pick-one list scoped to "which window fills the other half," reusing
/// `FuzzyMatch` the same way the palette does, not its whole state machine.
@Observable
@MainActor
final class WindowLayoutPartnerSearchState {
    var query = "" {
        didSet { selectedIndex = min(selectedIndex, max(filtered.count - 1, 0)) }
    }
    private(set) var candidates: [PartnerWindowCandidate] = []
    var selectedIndex = 0

    var filtered: [PartnerWindowCandidate] {
        guard !query.isEmpty else { return candidates }
        return candidates
            .compactMap { c in FuzzyMatch.score(query: query, target: c.appName).map { (c, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var selected: PartnerWindowCandidate? {
        let list = filtered
        return list.indices.contains(selectedIndex) ? list[selectedIndex] : nil
    }

    /// Rebuilds the candidate list, excluding `excludingPID` (the window
    /// already committed to its half). `preselect`, if present in the
    /// list, sorts first — so Enter with no typing reproduces the old
    /// auto-pair-with-previous-app behavior.
    func reload(excludingPID: pid_t, preselect: pid_t?) {
        query = ""
        var list = PartnerWindowCandidate.others(excludingPID: excludingPID)
        if let preselect, let i = list.firstIndex(where: { $0.pid == preselect }), i != 0 {
            list.swapAt(0, i)
        }
        candidates = list
        selectedIndex = 0
    }

    func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }
}
