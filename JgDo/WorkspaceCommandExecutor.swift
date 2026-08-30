import AppKit

/// Stage 2 of Natural-Language Workspace Creation: turns a VALIDATED
/// `WorkspaceCommand` into actual window placement. This is the only place
/// parsed text ever reaches anything that touches a real window/process —
/// and even then, only through the same narrow, existing primitives every
/// other feature in the app already uses (`WindowResizeService`,
/// `WindowManagerService.applyFrame`, `NSWorkspace.openApplication`). There
/// is no code path here (or anywhere upstream of here) that runs a shell
/// command or spawns an arbitrary process from parsed text.
@MainActor
final class WorkspaceCommandExecutor {
    static let shared = WorkspaceCommandExecutor()
    private let windowService = WindowManagerService()

    private init() {}

    // MARK: - Validation (pure, unit-testable — see WorkspaceCommandExecutorTests)

    struct ValidatedPlacement: Equatable {
        let appName: String   // resolved to a REAL installed app's exact name
        let layout: WindowLayout
        let screenIndex: Int?   // resolved to a currently-connected screen, or nil
    }

    struct ValidatedCommand: Equatable {
        let placements: [ValidatedPlacement]
        let appsToClose: [String]
        let issues: [String]   // human-readable, shown in the preview so nothing fails silently

        var isActionable: Bool { !placements.isEmpty || !appsToClose.isEmpty }
    }

    /// Never trusts a parsed `WorkspaceCommand` as-is: every app name is
    /// fuzzy-matched against apps that ACTUALLY exist on this Mac (an LLM
    /// provider can hallucinate a plausible-sounding app that isn't
    /// installed), and every `screenIndex` is checked against how many
    /// screens are ACTUALLY connected right now. Anything that can't be
    /// resolved is dropped from the actionable set and surfaced in `issues`
    /// instead of silently ignored or, worse, guessed at.
    nonisolated static func validate(_ command: WorkspaceCommand, installedAppNames: [String], screenCount: Int) -> ValidatedCommand {
        var issues: [String] = []

        let placements: [ValidatedPlacement] = command.placements.compactMap { p in
            guard let matched = bestMatch(for: p.appName, in: installedAppNames) else {
                issues.append("Couldn't find an app named “\(p.appName)”.")
                return nil
            }
            var screenIndex = p.screenIndex
            if let requested = screenIndex, !(0..<max(screenCount, 1)).contains(requested) {
                issues.append("“\(matched)”: display \(requested + 1) isn't connected — using its current display instead.")
                screenIndex = nil
            }
            return ValidatedPlacement(appName: matched, layout: p.layout, screenIndex: screenIndex)
        }

        let appsToClose: [String] = command.appsToClose.compactMap { name in
            guard let matched = bestMatch(for: name, in: installedAppNames) else {
                issues.append("Couldn't find an app named “\(name)” to close.")
                return nil
            }
            return matched
        }

        return ValidatedCommand(placements: placements, appsToClose: appsToClose, issues: issues)
    }

    private nonisolated static func bestMatch(for query: String, in candidates: [String]) -> String? {
        candidates
            .compactMap { name -> (String, Int)? in FuzzyMatch.score(query: query, target: name).map { (name, $0) } }
            .max { $0.1 < $1.1 }
            .map(\.0)
    }

    // MARK: - Execution

    /// Applies every placement and close in `validated`. Launches any
    /// placement app that isn't already running (`NSWorkspace.openApplication`)
    /// before trying to place it, polling (not blocking the main thread)
    /// for its first window to appear — same cadence/reasoning as
    /// `WorkspaceService.waitForWindows`, just expressed with `async`/
    /// `await` instead of a `DispatchGroup` since every other piece of this
    /// feature (the providers) is already async.
    ///
    /// Before/after frames for every window this call actually moves are
    /// recorded into `OrganizeUndoService.shared` — the SAME multi-window
    /// batch-undo "Clean Workspace" already uses, rather than a
    /// second/parallel undo mechanism just for this feature. The NL panel's
    /// own "Undo" button calls `OrganizeUndoService.shared.undo()`.
    func execute(_ validated: ValidatedCommand) async {
        for name in validated.appsToClose {
            NSWorkspace.shared.runningApplications
                .first(where: { $0.localizedName == name })?
                .terminate()
        }

        var moved: [(WindowInfo, CGRect)] = []
        for placement in validated.placements {
            guard let entry = await place(placement) else { continue }
            moved.append(entry)
        }
        guard !moved.isEmpty else { return }
        OrganizeUndoService.shared.record(moved)
    }

    /// Places one app's window and returns `(windowInfo, previousFrame)` —
    /// the "before" half of the pair `OrganizeUndoService.record` expects —
    /// or nil if the app couldn't be launched/found/placed. Always routes
    /// through `WindowManagerService.applyFrame`, the same primitive
    /// `OrganizeWorkspaceService`/`WorkspaceService` already use, resolving
    /// the target screen explicitly when the command named one, or via
    /// `CoordinateSpace.screen(containing:)` (the window's OWN current
    /// screen) otherwise — never assumes `NSScreen.main`.
    private func place(_ placement: ValidatedPlacement) async -> (WindowInfo, CGRect)? {
        guard let url = CommandPaletteState.installedApps.first(where: { $0.name == placement.appName })?.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        guard let app = await AppLaunchWaiter.launchOrFind(bundleID: bundleID) else { return nil }
        guard let windowInfo = windowService.fetchWindows().first(where: { $0.pid == app.processIdentifier }) else { return nil }

        let before = windowInfo.appKitFrame
        let screen: NSScreen?
        if let screenIndex = placement.screenIndex, NSScreen.screens.indices.contains(screenIndex) {
            screen = NSScreen.screens[screenIndex]
        } else {
            screen = CoordinateSpace.screen(containing: before)
        }
        guard let screen else { return nil }

        let frame = WindowResizeService.shared.frame(for: placement.layout, on: screen)
        windowService.applyFrame(frame, to: windowInfo, on: screen)
        return (windowInfo, before)
    }

}
