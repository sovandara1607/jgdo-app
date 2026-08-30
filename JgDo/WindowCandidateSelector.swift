import AppKit
import ApplicationServices
import os

/// The one canonical place that decides which OTHER open window should
/// fill the remaining side of a dual-snap (⌃⌥←/→'s auto-fill, every other
/// layout hotkey's own dual-snap, and the ⌥Space switcher's pick). Owns
/// eligible-window filtering, ranking (`WindowPartnerRanking`), pairing-
/// history scoring (`WindowPairService`), and recency scoring
/// (`HUDState.recentApps`) — nothing here moves a window or renders UI;
/// `WindowResizeService` still owns applying the result.
///
/// Consolidating this out of `WindowResizeService` matters because
/// eligibility rules used to only live in one call path — this is the
/// single filtering system every dual-snap caller now shares, so a rule
/// added here (or a bug fixed here) can't drift between features.
enum WindowCandidateSelector {

    /// Chooses the best OTHER visible window to pair with a dual-snap.
    /// `preferredScreen`, if given, is the primary window's own screen —
    /// candidates already on it are ranked higher, so a dual-snap on
    /// Monitor 1 doesn't reach across to grab a window from Monitor 2.
    /// Falls back to plain front-to-back order (the old "topmost visible
    /// window" heuristic) when there's no recency/same-display/pairing
    /// signal to break ties with.
    static func bestPartner(excluding frontPID: pid_t?, preferredScreen: NSScreen?) -> WindowInfo? {
        let windows = WindowManagerService().fetchWindows()   // front-to-back, excludes JgDo
        let frontBundleID = frontPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        let recentPIDs = HUDState.shared.recentApps.map(\.processIdentifier)

        var seenPIDs = Set<pid_t>()
        var byPID: [pid_t: WindowInfo] = [:]
        var candidates: [WindowPartnerRanking.Candidate] = []

        for (index, window) in windows.enumerated() {
            guard window.pid != frontPID, !seenPIDs.contains(window.pid) else { continue }
            seenPIDs.insert(window.pid)
            guard let app = NSRunningApplication(processIdentifier: window.pid) else { continue }
            guard isEligiblePartner(window, app: app) else { continue }
            let bundleID = app.bundleIdentifier
            let windowScreen = CoordinateSpace.screen(containing: CoordinateSpace.appKit(fromCG: window.bounds).origin)
            byPID[window.pid] = window
            candidates.append(WindowPartnerRanking.Candidate(
                pid: window.pid, bundleID: bundleID,
                recencyRank: recentPIDs.firstIndex(of: window.pid),
                isOnSameScreen: preferredScreen != nil && windowScreen == preferredScreen,
                pairScore: WindowPairService.shared.score(frontBundleID, bundleID),
                frontToBackIndex: index))
        }

        logScoring(candidates, byPID: byPID)
        guard let winner = WindowPartnerRanking.best(among: candidates) else { return nil }
        return byPID[winner.pid]
    }

    // MARK: - Eligibility

    /// Excludes obviously-wrong dual-snap partners. One canonical set of
    /// rules shared by every dual-snap caller — see the type doc.
    ///
    /// - Too small to be a meaningful half-screen tile (dialogs, utility
    ///   panels, tooltips).
    /// - A preferences/settings/about window by title (most apps don't
    ///   expose a distinct AX role for these).
    /// - Finder's desktop window specifically (bundle ID + no title —
    ///   a real Finder window, e.g. "Downloads", stays eligible).
    /// - An AX role/subrole that isn't a plain standard window: sheets,
    ///   system dialogs, and floating/HUD panels are excluded; a plain
    ///   `kAXWindowRole` with no subrole (or `kAXStandardWindowSubrole`)
    ///   is what a normal document/app window reports.
    /// - A window whose size AX reports as not settable (some panels are
    ///   intentionally fixed-size).
    ///
    /// Defaults to eligible when a check can't be resolved (e.g. AX lookup
    /// fails) rather than silently excluding a window on uncertainty —
    /// `fetchWindows()` already only returns on-screen, non-desktop-owner,
    /// reasonably-sized windows, so this is a second, stricter pass on
    /// top of that.
    private static func isEligiblePartner(_ window: WindowInfo, app: NSRunningApplication) -> Bool {
        guard window.bounds.width >= 260, window.bounds.height >= 160 else { return false }

        let title = window.windowTitle.lowercased()
        let excludedTitleWords = ["preferences", "settings", "about "]
        guard !excludedTitleWords.contains(where: title.contains) else { return false }

        if app.bundleIdentifier == "com.apple.finder", window.windowTitle.isEmpty { return false }

        guard let axWindow = WindowManagerService().axWindow(for: window) else { return true }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String, role != kAXWindowRole as String { return false }

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef)
        if let subrole = subroleRef as? String {
            let excludedSubroles: Set<String> = [
                kAXSystemDialogSubrole as String, kAXDialogSubrole as String,
                kAXFloatingWindowSubrole as String,
            ]
            guard !excludedSubroles.contains(subrole) else { return false }
        }

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(axWindow, kAXSizeAttribute as CFString, &settable)
        guard settable.boolValue else { return false }

        return true
    }

    // MARK: - Logging

    /// Debug-only scoring breakdown, e.g.:
    ///
    ///     Partner selection (excluding com.apple.dt.Xcode):
    ///       Safari: pairHistory +32.0 sameDisplay +40 recency +0 = 72.0
    ///       Terminal: pairHistory +0 sameDisplay +0 recency +30 = 30.0
    ///     → Selected: Safari
    ///
    /// App names only, never window titles/content — nothing sensitive.
    private static func logScoring(_ candidates: [WindowPartnerRanking.Candidate], byPID: [pid_t: WindowInfo]) {
        guard !candidates.isEmpty else { return }
        let winner = WindowPartnerRanking.best(among: candidates)
        for c in candidates {
            let b = WindowPartnerRanking.breakdown(c)
            let name = byPID[c.pid]?.appName ?? c.bundleID ?? "pid \(c.pid)"
            AppLog.window.debug("""
                Partner candidate \(name, privacy: .public): \
                pairHistory +\(b.pairHistory, privacy: .public) \
                sameDisplay +\(b.sameDisplay, privacy: .public) \
                recency +\(b.recency, privacy: .public) = \(b.total, privacy: .public)
                """)
        }
        if let winner, let name = byPID[winner.pid]?.appName {
            AppLog.window.debug("Partner selection → \(name, privacy: .public)")
        }
    }
}
