import AppKit
import SwiftData
import ApplicationServices
import os

/// Saves and restores named window arrangements ("workspaces").
/// Frames are stored in AppKit coordinates for the whole desktop, so a
/// workspace saved on a multi-monitor setup restores across all screens.
@Observable
final class WorkspaceService {
    static let shared = WorkspaceService()

    private(set) var workspaces: [Workspace] = []
    /// Diagnostics from the most recently completed `restore(_:)` call —
    /// which apps/windows were placed and which weren't, and why. The
    /// status popover surfaces this via a floating notice when anything
    /// didn't fully succeed; nil while a restore is still in flight or
    /// before any restore has run this launch.
    private(set) var lastRestoreDiagnostics: RestoreDiagnostics?

    private let windowService = WindowManagerService()
    private let persistence: PersistenceProviding

    /// `persistence` defaults to the real on-disk store — only tests pass
    /// something else, to exercise save/restore against an isolated
    /// in-memory container instead of the user's actual workspace history.
    /// `.shared` (used everywhere in the app) always gets the default.
    /// `nil` rather than defaulting the parameter straight to
    /// `Persistence.shared` — a MainActor-isolated default *argument
    /// expression* is evaluated outside the initializer's own isolation,
    /// which the compiler flags; resolving the fallback in the body avoids
    /// that entirely.
    init(persistence: PersistenceProviding? = nil) {
        self.persistence = persistence ?? Persistence.shared
        reload()
    }

    func reload() {
        let ctx = persistence.context
        let fetched = ctx.fetchLogged(FetchDescriptor<Workspace>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]), using: AppLog.workspace)
        // Bool isn't Comparable, so favorites-first is a stable sort here
        // rather than a second SortDescriptor.
        workspaces = fetched.sorted { $0.isFavorite && !$1.isFavorite }
    }

    // MARK: Capture

    /// Snapshot every visible standard window into a new workspace.
    @discardableResult
    func saveCurrentLayout(named name: String) -> Workspace? {
        let windows = windowService.fetchWindows()
        guard !windows.isEmpty else { return nil }

        let running = NSWorkspace.shared.runningApplications
        let workspace = Workspace(name: name)

        for info in windows {
            guard let app = running.first(where: { $0.processIdentifier == info.pid }),
                  let bundleID = app.bundleIdentifier else {
                AppLog.workspace.notice("Workspace save: skipping a window with no matching running app (pid \(info.pid)).")
                continue
            }
            let appKit = CoordinateSpace.appKit(fromCG: info.bounds)
            let screen = CoordinateSpace.screen(containing: appKit)
            let entry = WorkspaceWindow(bundleID: bundleID,
                                        appName: info.appName,
                                        title: info.windowTitle,
                                        frame: appKit,
                                        displayUUID: screen.flatMap { Self.displayUUID(for: $0) })
            entry.workspace = workspace
            workspace.windows.append(entry)
        }
        guard !workspace.windows.isEmpty else { return nil }

        persistence.context.insert(workspace)
        persistence.save()
        reload()
        return workspace
    }

    /// The stable identifier for `screen`'s physical display — survives
    /// display arrangement changes better than raw coordinates, so restore
    /// can tell "this exact monitor is disconnected" apart from "nothing
    /// currently overlaps this position" (which can coincidentally match a
    /// different, surviving screen at the same coordinates).
    static func displayUUID(for screen: NSScreen) -> String? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuidRef = CGDisplayCreateUUIDFromDisplayID(screenNumber) else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, uuidRef.takeRetainedValue()) as String?
    }

    // MARK: Restore

    /// One window's saved placement, detached from the SwiftData model so it
    /// can cross into launch-completion closures safely.
    private struct SavedPlacement {
        let frame: CGRect
        let title: String?
        let displayUUID: String?
    }

    /// Reapply a saved workspace: launch missing apps, then place each app's
    /// windows at their saved frames. Diagnostics for the whole call land in
    /// `lastRestoreDiagnostics` once every app (running, freshly launched,
    /// or not installed) has been accounted for.
    func restore(_ workspace: Workspace) {
        workspace.lastUsedAt = Date()
        persistence.save()

        // Saved placements per app, in z-order (front first).
        var placementsByBundle: [String: [SavedPlacement]] = [:]
        var appNameByBundle: [String: String] = [:]
        for w in workspace.windows {
            placementsByBundle[w.bundleID, default: []]
                .append(SavedPlacement(frame: w.frame, title: w.title, displayUUID: w.displayUUID))
            appNameByBundle[w.bundleID] = w.appName
        }

        lastRestoreDiagnostics = nil
        let diagnostics = RestoreDiagnostics()
        let group = DispatchGroup()

        for (bundleID, placements) in placementsByBundle {
            let appName = appNameByBundle[bundleID] ?? bundleID
            group.enter()
            if let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == bundleID }) {
                place(app: app, placements: placements, appName: appName, diagnostics: diagnostics)
                group.leave()
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, error in
                    guard let self else { group.leave(); return }
                    guard let app else {
                        AppLog.workspace.error("Workspace restore: failed to launch \(appName, privacy: .public): \(error?.localizedDescription ?? "unknown error", privacy: .public)")
                        diagnostics.record(.appProducedNoWindows(app: appName))
                        group.leave()
                        return
                    }
                    self.waitForWindows(app: app, placements: placements, appName: appName,
                                        diagnostics: diagnostics, attempt: 0, group: group)
                }
            } else {
                AppLog.workspace.notice("Workspace restore: \(bundleID, privacy: .public) has no installed app; skipping \(placements.count) saved window(s).")
                diagnostics.record(.appNotInstalled(app: appName))
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.lastRestoreDiagnostics = diagnostics
            if diagnostics.hasIssues {
                FloatingNoticeCenter.shared.show(
                    title: "Workspace Restored",
                    message: diagnostics.summary,
                    primaryTitle: "OK", secondaryTitle: nil,
                    onPrimary: {}
                )
            } else {
                // The clean-success path previously gave no feedback at
                // all — restoring silently did the right thing, but felt
                // indistinguishable from the shortcut not having fired.
                ActionToastCenter.shared.show("\(workspace.name) Workspace Restored", icon: "square.grid.2x2")
            }
        }
    }

    /// A freshly launched app doesn't have its first window ready
    /// immediately — this used to be a single fixed 1.5s wait regardless
    /// of how slow (or fast) the app actually was to open. Polls instead,
    /// so a fast app places right away and a slow one gets up to 5s rather
    /// than failing outright at 1.5s.
    private func waitForWindows(app: NSRunningApplication, placements: [SavedPlacement], appName: String,
                                 diagnostics: RestoreDiagnostics, attempt: Int, group: DispatchGroup) {
        let maxAttempts = 25 // 25 × 200ms ≈ 5s
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
           let axWindows = ref as? [AXUIElement], !axWindows.isEmpty {
            place(app: app, placements: placements, appName: appName, diagnostics: diagnostics)
            group.leave()
            return
        }
        guard attempt < maxAttempts else {
            AppLog.workspace.notice("Workspace restore: \(appName, privacy: .public) launched but produced no windows within 5s.")
            diagnostics.record(.appProducedNoWindows(app: appName))
            group.leave()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitForWindows(app: app, placements: placements, appName: appName,
                                 diagnostics: diagnostics, attempt: attempt + 1, group: group)
        }
    }

    /// Place an app's windows: match each saved placement to a live AX window
    /// by title first (AX window order is not the saved z-order, so blind
    /// zipping shuffles frames between same-app windows), then pair whatever
    /// is left positionally. Any saved placement with no live window left to
    /// claim (fewer windows open now than were saved) is recorded, not
    /// silently dropped.
    private func place(app: NSRunningApplication, placements: [SavedPlacement], appName: String, diagnostics: RestoreDiagnostics) {
        app.unhide()
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let axWindows = ref as? [AXUIElement], !axWindows.isEmpty else {
            AppLog.workspace.error("Workspace restore: couldn't read \(appName, privacy: .public)'s windows via Accessibility.")
            diagnostics.record(.appProducedNoWindows(app: appName))
            return
        }

        var unclaimed = axWindows
        var unmatched: [SavedPlacement] = []
        var matched = 0
        for placement in placements {
            if let title = placement.title, !title.isEmpty,
               let idx = unclaimed.firstIndex(where: { axTitle(of: $0) == title }) {
                apply(placement, to: unclaimed.remove(at: idx))
                matched += 1
            } else {
                unmatched.append(placement)
            }
        }
        for (placement, axWin) in zip(unmatched, unclaimed) {
            apply(placement, to: axWin)
            matched += 1
        }

        if matched < placements.count {
            AppLog.workspace.notice("Workspace restore: \(appName, privacy: .public) — only \(matched) of \(placements.count) saved windows matched a live window.")
        }
        diagnostics.record(.placed(app: appName, matched: matched, total: placements.count))
    }

    private func axTitle(of axWindow: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString,
                                            &ref) == .success else { return nil }
        return ref as? String
    }

    /// Resolves which screen `placement` should land on and whether that's
    /// a genuine remap (its saved display is confirmed disconnected) versus
    /// its original screen (or an unknown one, for placements saved before
    /// `displayUUID` existed) — see `apply(_:to:)`.
    private func resolveScreen(for placement: SavedPlacement) -> (screen: NSScreen, remapped: Bool) {
        if let uuid = placement.displayUUID,
           let match = NSScreen.screens.first(where: { Self.displayUUID(for: $0) == uuid }) {
            return (match, false)
        }
        let fallback = CoordinateSpace.screen(containing: CGPoint(x: placement.frame.midX, y: placement.frame.midY))
            ?? NSScreen.main ?? NSScreen.screens[0]
        // A recorded UUID that didn't match anything currently connected
        // means the original monitor is confirmed gone — the raw saved
        // position is no longer trustworthy (it could coincidentally
        // overlap a surviving screen at the wrong spot), so treat this as
        // a real remap and recenter rather than placing it at that stale
        // position. No UUID at all (pre-existing saves) keeps the old
        // "trust the geometry" behavior instead.
        return (fallback, placement.displayUUID != nil)
    }

    private func apply(_ placement: SavedPlacement, to axWin: AXUIElement) {
        let (screen, remapped) = resolveScreen(for: placement)
        var frame = placement.frame
        if remapped {
            let vf = screen.visibleFrame
            frame = CGRect(x: vf.midX - frame.width / 2, y: vf.midY - frame.height / 2,
                            width: min(frame.width, vf.width), height: min(frame.height, vf.height))
        }
        WindowManagerService.setAXFrame(CoordinateSpace.cg(fromAppKit: frame), of: axWin)
    }

    // MARK: Restore on launch

    /// Called once at app launch — restores every workspace flagged
    /// `restoreOnLaunch`, most-recently-created first.
    func restoreWorkspacesFlaggedForLaunch() {
        for workspace in workspaces where workspace.restoreOnLaunch {
            restore(workspace)
        }
    }

    // MARK: Management

    func delete(_ workspace: Workspace) {
        persistence.context.delete(workspace)
        persistence.save()
        reload()
    }

    func rename(_ workspace: Workspace, to name: String) {
        workspace.name = name
        persistence.save()
        reload()
    }

    /// Deep-copies a workspace and its windows under a new name.
    @discardableResult
    func duplicate(_ workspace: Workspace, named name: String) -> Workspace {
        let copy = Workspace(name: name, symbolName: workspace.symbolName)
        for w in workspace.windows {
            let windowCopy = WorkspaceWindow(bundleID: w.bundleID, appName: w.appName, title: w.title,
                                              frame: w.frame, displayUUID: w.displayUUID)
            windowCopy.workspace = copy
            copy.windows.append(windowCopy)
        }
        persistence.context.insert(copy)
        persistence.save()
        reload()
        return copy
    }

    func setRestoreOnLaunch(_ enabled: Bool, for workspace: Workspace) {
        workspace.restoreOnLaunch = enabled
        persistence.save()
        reload()
    }

    func toggleFavorite(_ workspace: Workspace) {
        workspace.isFavorite.toggle()
        persistence.save()
        reload()
    }
}
