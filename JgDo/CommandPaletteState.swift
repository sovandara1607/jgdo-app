import AppKit

/// State for the Spotlight-style Command Palette — a window-level switcher
/// (distinct from `HUDState`'s app-level ⌥Space switcher). Groups windows by
/// owning app, fuzzy-filters them, and tracks a flat, accordion-style
/// selection: `groupIndex` is the one app currently expanded inline (showing
/// each of its windows as its own row); every other group collapses to a
/// single summary row. `rowIndex` is the selected window within that
/// expanded group.
@Observable
final class CommandPaletteState {
    static let shared = CommandPaletteState()

    struct AppGroup: Identifiable {
        let id: pid_t
        let appName: String
        let icon: NSImage?
        var windows: [WindowInfo]
    }

    var searchText = ""
    var groupIndex = 0
    var rowIndex = 0
    var focusSearch = false

    private let service = WindowManagerService()
    private(set) var allGroups: [AppGroup] = []

    private init() {}

    /// Re-fetches live windows and regroups. Call every time the palette opens.
    func reload() {
        let windows = service.fetchWindows()
        var byPID: [pid_t: [WindowInfo]] = [:]
        var discoveryOrder: [pid_t] = []
        for w in windows {
            if byPID[w.pid] == nil { discoveryOrder.append(w.pid) }
            byPID[w.pid, default: []].append(w)
        }

        // Recency: HUDState's MRU app list first, then any remaining apps in
        // their fetchWindows() (z-order) discovery order.
        let recentPIDs = HUDState.shared.recentApps
            .filter { !$0.isTerminated }
            .map { $0.processIdentifier }
        var seen = Set<pid_t>()
        var orderedPIDs: [pid_t] = []
        for pid in recentPIDs where byPID[pid] != nil {
            orderedPIDs.append(pid)
            seen.insert(pid)
        }
        for pid in discoveryOrder where !seen.contains(pid) {
            orderedPIDs.append(pid)
            seen.insert(pid)
        }

        allGroups = orderedPIDs.compactMap { pid in
            guard let ws = byPID[pid], let first = ws.first else { return nil }
            let icon = NSRunningApplication(processIdentifier: pid)?.icon ?? first.icon
            return AppGroup(id: pid, appName: first.appName, icon: icon, windows: ws)
        }
        searchText = ""
        groupIndex = 0
        rowIndex = 0
    }

    /// Groups filtered by fuzzy match on app name + window title. Groups with
    /// no matching windows are dropped; surviving groups keep only matching
    /// windows, best-scored first.
    var filteredGroups: [AppGroup] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return allGroups }
        return allGroups.compactMap { group in
            let scored: [(WindowInfo, Int)] = group.windows.compactMap { w in
                guard let s = FuzzyMatch.bestScore(query: q, targets: [group.appName, w.windowTitle]) else { return nil }
                return (w, s)
            }
            guard !scored.isEmpty else { return nil }
            var g = group
            g.windows = scored.sorted { $0.1 > $1.1 }.map(\.0)
            return g
        }
    }

    var selectedWindow: WindowInfo? {
        let groups = filteredGroups
        guard groups.indices.contains(groupIndex), groups[groupIndex].windows.indices.contains(rowIndex) else { return nil }
        return groups[groupIndex].windows[rowIndex]
    }

    /// Keeps `groupIndex`/`rowIndex` valid after the filtered set changes
    /// (e.g. every keystroke in search).
    func clampSelection() {
        let groups = filteredGroups
        groupIndex = groups.isEmpty ? 0 : min(max(groupIndex, 0), groups.count - 1)
        let rows = groups.indices.contains(groupIndex) ? groups[groupIndex].windows.count : 0
        rowIndex = rows == 0 ? 0 : min(max(rowIndex, 0), rows - 1)
    }

    /// Moves the selection by one row (`delta` is ±1 per key press). Stepping
    /// past the last window of the expanded group collapses it and expands
    /// the next group, landing on its first window (and symmetrically at the
    /// top) — a single flat list, wrapping at either end.
    func move(_ delta: Int) {
        let groups = filteredGroups
        guard !groups.isEmpty else { return }
        guard groups.indices.contains(groupIndex) else { groupIndex = 0; rowIndex = 0; return }

        var newGroup = groupIndex
        var newRow = rowIndex + delta
        if newRow < 0 {
            newGroup = (newGroup - 1 + groups.count) % groups.count
            newRow = groups[newGroup].windows.count - 1
        } else if newRow >= groups[newGroup].windows.count {
            newGroup = (newGroup + 1) % groups.count
            newRow = 0
        }
        groupIndex = newGroup
        rowIndex = max(newRow, 0)
    }
}
