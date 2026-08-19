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

    // MARK: - `>` quick actions

    /// A command typed as `>verb [target]`, e.g. `>quit Safari`, `>hide`
    /// (no target = act on the MRU/frontmost app). Parsed from `searchText`
    /// so the palette can double as "type a window name" or "type a
    /// command" without a mode switch.
    enum QuickAction: String, CaseIterable {
        case quit, hide, minimize

        var verbCapitalized: String { rawValue.capitalized }
    }

    struct ParsedCommand {
        let action: QuickAction
        let targetName: String?
    }

    var searchText = ""
    var groupIndex = 0
    var rowIndex = 0
    var focusSearch = false

    private let service = WindowManagerService()
    private(set) var allGroups: [AppGroup] = []

    private init() {}

    // MARK: - "Launch ‹App›" suggestions

    /// Sentinel pid range for launch-suggestion rows (apps matched by the
    /// query that aren't currently running) — negative so they never
    /// collide with a real pid (always positive). `pickPaletteWindow`
    /// checks `pid < 0` to route these to `NSWorkspace.openApplication`
    /// instead of focusing a window.
    private static let launchPIDBase: pid_t = -1000

    /// Installed .app bundles (name + URL), scanned once per process launch
    /// (a few cheap directory listings) rather than on every keystroke.
    /// Keeping the URL from the scan itself — rather than re-deriving it
    /// later via the deprecated `NSWorkspace.fullPath(forApplication:)` —
    /// is also what `launchTargetURL(forAppName:)` hands back to
    /// `AppDelegate` at pick time.
    private static let installedApps: [(name: String, url: URL)] = {
        let fm = FileManager.default
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var apps: [(name: String, url: URL)] = []
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let name = (entry as NSString).deletingPathExtension
                guard !seen.contains(name) else { continue }
                seen.insert(name)
                apps.append((name, URL(fileURLWithPath: dir + "/" + entry)))
            }
        }
        return apps.sorted { $0.name < $1.name }
    }()

    /// The bundle URL for an installed app matched by exact display name —
    /// used by `AppDelegate.pickPaletteWindow` to launch a "Launch ‹App›"
    /// suggestion.
    func launchTargetURL(forAppName name: String) -> URL? {
        Self.installedApps.first { $0.name == name }?.url
    }

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
            let runningApp = NSRunningApplication(processIdentifier: pid)
            let icon = runningApp?.icon ?? first.icon
            // Browser tab search: expand each window into one row per open
            // tab when the app exposes the public `AXTabs` attribute.
            // Skipped entirely for non-browsers — no wasted AX round-trips.
            let expanded = BrowserTabService.isKnownBrowser(bundleID: runningApp?.bundleIdentifier)
                ? ws.flatMap(expandTabs)
                : ws
            return AppGroup(id: pid, appName: first.appName, icon: icon, windows: expanded)
        }
        searchText = ""
        groupIndex = 0
        rowIndex = 0
    }

    /// Splits one browser window into one row per open tab via the public
    /// `AXTabs` attribute, when available — the documented graceful
    /// fallback ("window-title searching") is simply returning `[window]`
    /// unchanged when there's no tab info (fewer than 2 tabs reported, or
    /// the browser doesn't expose the attribute at all).
    private func expandTabs(for window: WindowInfo) -> [WindowInfo] {
        guard let axWindow = service.axWindow(for: window) else { return [window] }
        let tabs = BrowserTabService.tabs(of: axWindow)
        guard tabs.count > 1 else { return [window] }
        return tabs.map { tab in
            WindowInfo(windowID: window.windowID, appName: window.appName, windowTitle: tab.title,
                       pid: window.pid, icon: window.icon, bounds: window.bounds,
                       screenLabel: window.screenLabel, axTabElement: tab.axElement)
        }
    }

    /// Groups filtered by fuzzy match on app name + window title. Groups with
    /// no matching windows are dropped; surviving groups keep only matching
    /// windows, best-scored first. `>` mode (see `parsedCommand`) replaces
    /// this entirely with action rows.
    var filteredGroups: [AppGroup] {
        if let cmd = parsedCommand { return actionGroups(for: cmd) }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return allGroups }
        let matched: [AppGroup] = allGroups.compactMap { group in
            let scored: [(WindowInfo, Int)] = group.windows.compactMap { w in
                guard let s = FuzzyMatch.bestScore(query: q, targets: [group.appName, w.windowTitle]) else { return nil }
                return (w, s)
            }
            guard !scored.isEmpty else { return nil }
            var g = group
            g.windows = scored.sorted { $0.1 > $1.1 }.map(\.0)
            return g
        }
        return matched + launchGroups(matching: q)
    }

    /// Parses `searchText` as a `>verb [target]` command, e.g. `>quit
    /// Safari` or `>hide`. Anything not starting with `>`, or with an
    /// unrecognized verb, is nil — normal window search takes over.
    var parsedCommand: ParsedCommand? {
        guard searchText.hasPrefix(">") else { return nil }
        let body = searchText.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        let parts = body.split(separator: " ", maxSplits: 1)
        guard let verb = QuickAction(rawValue: parts[0].lowercased()) else { return nil }
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
        return ParsedCommand(action: verb, targetName: (rest?.isEmpty ?? true) ? nil : rest)
    }

    /// Up to 5 "‹Verb› ‹App›" rows for a parsed `>` command — reuses the
    /// existing `AppGroup`/row rendering rather than a parallel UI. Each
    /// row's `WindowInfo.pid` is the REAL target app's pid (so execution
    /// can dispatch on it directly); the sentinel lives on the `AppGroup.id`
    /// instead, mirroring `launchGroups`' `launchPIDBase` pattern.
    private static let actionPIDBase: pid_t = -5000

    private func actionGroups(for cmd: ParsedCommand) -> [AppGroup] {
        let candidates: [AppGroup]
        if let name = cmd.targetName, !name.isEmpty {
            candidates = allGroups
                .compactMap { g -> (AppGroup, Int)? in
                    guard let s = FuzzyMatch.bestScore(query: name, targets: [g.appName]) else { return nil }
                    return (g, s)
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        } else if let front = allGroups.first {
            // allGroups is already MRU-ordered (see reload()) — with no
            // target name, act on whichever app that puts first.
            candidates = [front]
        } else {
            candidates = []
        }

        return candidates.prefix(5).enumerated().map { i, group in
            let pid = Self.actionPIDBase - pid_t(i)
            let label = "\(cmd.action.verbCapitalized) \(group.appName)"
            let actionWindow = WindowInfo(windowID: 0, appName: group.appName, windowTitle: label,
                                           pid: group.id, icon: group.icon, bounds: .zero)
            return AppGroup(id: pid, appName: group.appName, icon: group.icon, windows: [actionWindow])
        }
    }

    /// Up to 3 "Launch ‹App›" rows for installed apps that fuzzy-match `q`
    /// and aren't already running (i.e. not already represented by a real
    /// window group) — turns the palette into a launcher, not just a
    /// switcher, once a query stops matching any open window.
    private func launchGroups(matching q: String) -> [AppGroup] {
        let runningNames = Set(allGroups.map { $0.appName.lowercased() })
        let ranked = Self.installedApps
            .filter { !runningNames.contains($0.name.lowercased()) }
            .compactMap { app -> (name: String, url: URL, score: Int)? in
                guard let s = FuzzyMatch.bestScore(query: q, targets: [app.name]) else { return nil }
                return (app.name, app.url, s)
            }
            .sorted { $0.score > $1.score }
            .prefix(3)

        return ranked.enumerated().map { i, entry in
            let pid = Self.launchPIDBase - pid_t(i)
            let icon = NSWorkspace.shared.icon(forFile: entry.url.path)
            let launchWindow = WindowInfo(windowID: 0, appName: entry.name,
                                           windowTitle: "Launch “\(entry.name)”",
                                           pid: pid, icon: icon, bounds: .zero)
            return AppGroup(id: pid, appName: entry.name, icon: icon, windows: [launchWindow])
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
