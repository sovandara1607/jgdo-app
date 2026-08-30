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
        /// nil for launch-suggestion/quick-action rows (sentinel pids).
        var bundleID: String?
    }

    // MARK: - `>` quick actions

    /// A command typed as `>verb [target]`, e.g. `>quit Safari`, `>hide`
    /// (no target = act on the MRU/frontmost app). Parsed from `searchText`
    /// so the palette can double as "type a window name" or "type a
    /// command" without a mode switch.
    enum QuickAction: String, CaseIterable {
        case quit, hide, minimize, float

        var verbCapitalized: String { rawValue.capitalized }
    }

    struct ParsedCommand {
        let action: QuickAction
        let targetName: String?
    }

    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            FileSearchService.shared.search(searchText)
        }
    }
    var groupIndex = 0
    var rowIndex = 0
    var focusSearch = false

    // MARK: - File Search section (appended after window/launch groups)
    //
    // A third "virtual group" at the tail of the same flat, keyboard-
    // navigable sequence `groupIndex`/`rowIndex` already walks — see
    // `move(_:)`. Kept as separate state (not folded into `AppGroup`/
    // `WindowInfo`) because files carry richer metadata (full path, kind,
    // size) and more actions (Open/Reveal/Copy Path/Copy URL/Quick Look)
    // than a window row's single "pick" action.
    var fileResults: [FileSearchResult] { FileSearchService.shared.results }
    /// True once the flat selection has moved past every app/launch group
    /// into the file-results section.
    var fileSectionActive = false
    var fileIndex = 0
    var selectedFile: FileSearchResult? {
        guard fileSectionActive, fileResults.indices.contains(fileIndex) else { return nil }
        return fileResults[fileIndex]
    }

    // MARK: - Layout commands ("safari left", "snap left", "tile left", …)
    //
    // A second "virtual group" tier, inserted between window/launch groups
    // and the file-results tier (see `move(_:)`) — recognition-over-
    // memorization: the user doesn't need to remember `⌥←` at all if they'd
    // rather just type what they want.

    /// One "Snap ‹App› ‹Layout›" row. `targetPID` is the real app to act on
    /// (not a sentinel) — resolved the same way `>` quick actions resolve
    /// their implicit target: an app named in the query if one matched,
    /// else the current/MRU-front app.
    struct PaletteCommand: Identifiable {
        let id = UUID()
        let layout: WindowLayout
        let targetPID: pid_t
        let targetAppName: String
        let targetIcon: NSImage?
        /// Nil when no hotkey is bound to this exact layout (some layouts,
        /// like the corner tiles, share a modifier chord scheme that isn't
        /// meaningfully "the" shortcut for display here) — the row just
        /// omits the chip rather than showing a misleading blank.
        let shortcutDisplay: String?

        var label: String { "Snap \(targetAppName) \(layout.rawValue)" }
    }

    /// True when `commandResults` is showing recent commands rather than a
    /// live keyword match — the view uses this to switch the section
    /// header between "RECENT" and "WINDOW".
    var commandResultsAreRecent: Bool {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Empty query: up to 5 recently-applied layout commands, for apps that
    /// are still running. Non-empty query: at most one row — the single
    /// layout keyword found in the text (see
    /// `NaturalLanguageProviding.RuleBasedProvider.keywordLayouts`, reused
    /// as-is rather than a second alias list), applied to whichever app the
    /// query also names, or the current/MRU app if it names none. Doesn't
    /// run at all in `>` mode — that already owns the row list for its own
    /// verbs.
    var commandResults: [PaletteCommand] {
        guard parsedCommand == nil else { return [] }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return recentCommandResults() }
        guard let layout = Self.matchedLayout(in: q) else { return [] }

        let lower = q.lowercased()
        let target = allGroups.first(where: { lower.contains($0.appName.lowercased()) }) ?? allGroups.first
        guard let target else { return [] }
        return [makeCommand(layout: layout, target: target)]
    }

    private func recentCommandResults() -> [PaletteCommand] {
        RecentCommandsStore.recent.compactMap { entry in
            guard let target = allGroups.first(where: { $0.bundleID == entry.bundleID }) else { return nil }
            return makeCommand(layout: entry.layout, target: target)
        }
    }

    private func makeCommand(layout: WindowLayout, target: AppGroup) -> PaletteCommand {
        let shortcut = HotkeyAction.allCases
            .first(where: { $0.layout == layout })
            .map { ShortcutStore.shared.combo(for: $0).display }
        return PaletteCommand(layout: layout, targetPID: target.id, targetAppName: target.appName,
                               targetIcon: target.icon, shortcutDisplay: shortcut)
    }

    /// First alias phrase (checked in the shared table's own longest-first
    /// order) that appears anywhere in `text` — plain substring containment,
    /// so "snap left"/"move left"/"tile left"/"window left" all resolve to
    /// `.leftHalf` via the same bare "left" entry, with no separate alias
    /// list to keep in sync. Not `private`: unit-testable in isolation
    /// (`CommandPaletteStateTests`), same reasoning as `FileSearchService`'s
    /// own "pure helpers" section — no AppKit/live-window dependency here.
    static func matchedLayout(in text: String) -> WindowLayout? {
        let lower = text.lowercased()
        for (phrase, layout) in RuleBasedProvider.keywordLayouts where lower.contains(phrase) {
            return layout
        }
        return nil
    }

    var commandSectionActive = false
    var commandIndex = 0
    var selectedCommand: PaletteCommand? {
        guard commandSectionActive, commandResults.indices.contains(commandIndex) else { return nil }
        return commandResults[commandIndex]
    }

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
    /// `AppDelegate` at pick time. Not `private`: `NaturalLanguageService`/
    /// `WorkspaceCommandExecutor` reuse this exact scan as their "which
    /// apps actually exist" grounding data rather than re-scanning
    /// `/Applications` a second time.
    static let installedApps: [(name: String, url: URL)] = {
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

        let favorites = AppSettings.favoriteAppBundleIDs
        let unsorted = orderedPIDs.compactMap { pid -> AppGroup? in
            guard let ws = byPID[pid], let first = ws.first else { return nil }
            let runningApp = NSRunningApplication(processIdentifier: pid)
            let icon = runningApp?.icon ?? first.icon
            // Browser tab search: expand each window into one row per open
            // tab when the app exposes the public `AXTabs` attribute.
            // Skipped entirely for non-browsers — no wasted AX round-trips.
            let expanded = BrowserTabService.isKnownBrowser(bundleID: runningApp?.bundleIdentifier)
                ? ws.flatMap(expandTabs)
                : ws
            return AppGroup(id: pid, appName: first.appName, icon: icon, windows: expanded,
                             bundleID: runningApp?.bundleIdentifier)
        }
        // Favorites float to the top, MRU order preserved otherwise.
        allGroups = unsorted.sorted { g1, g2 in
            let f1 = g1.bundleID.map(favorites.contains) ?? false
            let f2 = g2.bundleID.map(favorites.contains) ?? false
            return f1 && !f2
        }
        searchText = ""
        groupIndex = 0
        rowIndex = 0
        commandSectionActive = false
        commandIndex = 0
        fileSectionActive = false
        fileIndex = 0
        // `searchText`'s `didSet` only fires the file search on an actual
        // *change* — if it was already "" from the last time the palette
        // closed, the line above is a no-op and recent files wouldn't
        // refresh on reopen. Call explicitly so opening the palette always
        // starts a fresh recent-files query.
        FileSearchService.shared.search(searchText)
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

    /// Toggles favorite status and re-sorts `allGroups` in place — doesn't
    /// call `reload()`, which would wipe the current search text/selection.
    func toggleFavoriteApp(bundleID: String) {
        var favs = AppSettings.favoriteAppBundleIDs
        if favs.contains(bundleID) { favs.remove(bundleID) } else { favs.insert(bundleID) }
        AppSettings.favoriteAppBundleIDs = favs
        allGroups.sort { g1, g2 in
            let f1 = g1.bundleID.map(favs.contains) ?? false
            let f2 = g2.bundleID.map(favs.contains) ?? false
            return f1 && !f2
        }
    }

    var selectedWindow: WindowInfo? {
        let groups = filteredGroups
        guard groups.indices.contains(groupIndex), groups[groupIndex].windows.indices.contains(rowIndex) else { return nil }
        return groups[groupIndex].windows[rowIndex]
    }

    /// Keeps `groupIndex`/`rowIndex` (and the command/file sections' own
    /// indices) valid after the filtered set changes (e.g. every keystroke
    /// in search). Typing always returns focus to the first non-empty tier
    /// in the sequence — window/launch groups, then the (at most one)
    /// layout command, then files — matching "windows first, everything
    /// else reachable by explicitly arrowing past the end."
    func clampSelection() {
        let groups = filteredGroups
        if !groups.isEmpty {
            groupIndex = min(max(groupIndex, 0), groups.count - 1)
            let rows = groups.indices.contains(groupIndex) ? groups[groupIndex].windows.count : 0
            rowIndex = rows == 0 ? 0 : min(max(rowIndex, 0), rows - 1)
            commandSectionActive = false
            fileSectionActive = false
        } else if !commandResults.isEmpty {
            groupIndex = 0
            rowIndex = 0
            commandSectionActive = true
            fileSectionActive = false
        } else {
            groupIndex = 0
            rowIndex = 0
            commandSectionActive = false
            fileSectionActive = !fileResults.isEmpty
        }
        commandIndex = commandResults.isEmpty ? 0 : min(max(commandIndex, 0), commandResults.count - 1)
        fileIndex = fileResults.isEmpty ? 0 : min(max(fileIndex, 0), fileResults.count - 1)
    }

    /// Tab — jumps straight to the next/previous app group's collapsed row,
    /// skipping past however many windows the current group has. No-op
    /// while browsing commands/files (those aren't grouped).
    func jumpGroup(_ delta: Int) {
        guard !commandSectionActive, !fileSectionActive else { return }
        let groups = filteredGroups
        guard !groups.isEmpty else { return }
        groupIndex = (groupIndex + delta + groups.count) % groups.count
        rowIndex = 0
    }

    /// Moves the selection by one row (`delta` is ±1 per key press). Stepping
    /// past the last window of the expanded group collapses it and expands
    /// the next group, landing on its first window (and symmetrically at the
    /// top) — a single flat list, wrapping at either end. The (at most one)
    /// layout command and file results, if any, are two more "virtual
    /// group" tiers appended at the tail of that same circular sequence, in
    /// that order (groups → command → files): stepping past the last window
    /// group enters the command tier if present, else the file tier if
    /// present, and symmetrically backward from the first group's first row.
    /// With no command/file results, this is byte-identical to the
    /// window-only behavior it replaces — every `hasCommands`/`hasFiles`
    /// branch below just falls through to its neighbor when empty.
    func move(_ delta: Int) {
        let groups = filteredGroups
        let hasCommands = !commandResults.isEmpty
        let hasFiles = !fileResults.isEmpty

        if fileSectionActive {
            let newIndex = fileIndex + delta
            if newIndex < 0 {
                if hasCommands {
                    fileSectionActive = false
                    commandSectionActive = true
                    commandIndex = commandResults.count - 1
                } else if !groups.isEmpty {
                    fileSectionActive = false
                    groupIndex = groups.count - 1
                    rowIndex = max(groups[groupIndex].windows.count - 1, 0)
                } else {
                    fileIndex = max(fileResults.count - 1, 0)
                }
            } else if newIndex >= fileResults.count {
                if !groups.isEmpty {
                    fileSectionActive = false
                    groupIndex = 0
                    rowIndex = 0
                } else if hasCommands {
                    fileSectionActive = false
                    commandSectionActive = true
                    commandIndex = 0
                } else {
                    fileIndex = 0
                }
            } else {
                fileIndex = newIndex
            }
            return
        }

        if commandSectionActive {
            let newIndex = commandIndex + delta
            if newIndex < 0 {
                if !groups.isEmpty {
                    commandSectionActive = false
                    groupIndex = groups.count - 1
                    rowIndex = max(groups[groupIndex].windows.count - 1, 0)
                } else if hasFiles {
                    commandSectionActive = false
                    fileSectionActive = true
                    fileIndex = fileResults.count - 1
                } else {
                    commandIndex = max(commandResults.count - 1, 0)
                }
            } else if newIndex >= commandResults.count {
                if hasFiles {
                    commandSectionActive = false
                    fileSectionActive = true
                    fileIndex = 0
                } else if !groups.isEmpty {
                    commandSectionActive = false
                    groupIndex = 0
                    rowIndex = 0
                } else {
                    commandIndex = 0
                }
            } else {
                commandIndex = newIndex
            }
            return
        }

        guard !groups.isEmpty else {
            if hasCommands {
                commandSectionActive = true
                commandIndex = 0
            } else if hasFiles {
                fileSectionActive = true
                fileIndex = 0
            }
            return
        }
        guard groups.indices.contains(groupIndex) else { groupIndex = 0; rowIndex = 0; return }

        var newGroup = groupIndex
        var newRow = rowIndex + delta
        if newRow < 0 {
            if groupIndex == 0 {
                if hasFiles {
                    fileSectionActive = true
                    fileIndex = fileResults.count - 1
                    return
                } else if hasCommands {
                    commandSectionActive = true
                    commandIndex = commandResults.count - 1
                    return
                }
            }
            newGroup = (newGroup - 1 + groups.count) % groups.count
            newRow = groups[newGroup].windows.count - 1
        } else if newRow >= groups[newGroup].windows.count {
            if groupIndex == groups.count - 1 {
                if hasCommands {
                    commandSectionActive = true
                    commandIndex = 0
                    return
                } else if hasFiles {
                    fileSectionActive = true
                    fileIndex = 0
                    return
                }
            }
            newGroup = (newGroup + 1) % groups.count
            newRow = 0
        }
        groupIndex = newGroup
        rowIndex = max(newRow, 0)
    }
}
