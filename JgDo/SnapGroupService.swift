import AppKit
import SwiftData

/// Manual "Snap Groups" — the user explicitly captures the CURRENT on-screen
/// windows as a named group (no automatic/AI grouping, per spec: "do not
/// rely on automatic grouping initially"). Once created, the group can be
/// moved/resized/minimized/hidden/closed as a unit, and its members are
/// tagged with a small badge wherever Window Search shows them.
///
/// Scope note: "move entire group" and "resize entire group" are explicit,
/// menu-driven operations here, not a live ⌘-drag-follow (dragging one
/// grouped window doesn't drag its siblings in real time) — that would mean
/// hooking `WindowDragController`'s already-intricate live-tracking loop
/// with a third simultaneous mode, which is a much larger, riskier change
/// than this pass is worth. The menu actions below cover the same end
/// states (group ends up moved/resized together) deterministically.
@Observable
final class SnapGroupService {
    static let shared = SnapGroupService()

    private(set) var groups: [SnapGroup] = []
    private let windowService = WindowManagerService()

    private init() { reload() }

    func reload() {
        let ctx = Persistence.shared.context
        groups = (try? ctx.fetch(FetchDescriptor<SnapGroup>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
    }

    // MARK: Create / rename / delete

    /// Captures every current on-screen window (front-to-back) as a new
    /// named group, storing each one's shape as a fraction of the group's
    /// overall bounding box.
    @discardableResult
    func createGroup(named name: String) -> SnapGroup? {
        let windows = windowService.fetchWindows()
        guard !windows.isEmpty else { return nil }
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let appKitFrames: [(WindowInfo, CGRect)] = windows.map { w in
            (w, CGRect(x: w.bounds.minX, y: mainH - w.bounds.maxY, width: w.bounds.width, height: w.bounds.height))
        }
        let bbox = appKitFrames.dropFirst().reduce(appKitFrames[0].1) { $0.union($1.1) }
        guard bbox.width > 0, bbox.height > 0 else { return nil }

        let ctx = Persistence.shared.context
        let group = SnapGroup(name: name, bounds: bbox)
        for (w, frame) in appKitFrames {
            let bundleID = NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier ?? w.appName
            let fraction = CGRect(x: (frame.minX - bbox.minX) / bbox.width,
                                   y: (frame.minY - bbox.minY) / bbox.height,
                                   width: frame.width / bbox.width,
                                   height: frame.height / bbox.height)
            let member = SnapGroupMember(bundleID: bundleID, appName: w.appName,
                                          title: w.windowTitle, fraction: fraction)
            member.group = group
            group.members.append(member)
            ctx.insert(member)
        }
        ctx.insert(group)
        Persistence.shared.save()
        reload()
        return group
    }

    func rename(_ group: SnapGroup, to name: String) {
        group.name = name
        Persistence.shared.save()
        reload()
    }

    func delete(_ group: SnapGroup) {
        Persistence.shared.context.delete(group)
        Persistence.shared.save()
        reload()
    }

    /// The group name a window belongs to, if any — for the small badge
    /// Window Search rows show. Matched by app + title, the same identity
    /// members are captured with (AXUIElement refs don't survive relaunch).
    func groupName(forAppName appName: String, title: String) -> String? {
        groups.first { g in g.members.contains { $0.appName == appName && $0.title == title } }?.name
    }

    // MARK: Currently-open member resolution

    /// Resolves each member to its CURRENTLY open `WindowInfo`, if that
    /// window still exists — group operations only ever act on windows
    /// that are actually open right now; a member whose window closed (or
    /// whose app quit) is silently skipped, not an error.
    private func openWindows(for group: SnapGroup) -> [WindowInfo] {
        let current = windowService.fetchWindows()
        return group.members.compactMap { member in
            current.first {
                $0.appName == member.appName && $0.windowTitle == member.title
            }
        }
    }

    // MARK: Operations

    /// Puts every member window back at its captured position within the
    /// group's ORIGINAL bounding box — launching apps that aren't running,
    /// the same "restore a saved arrangement" contract as `WorkspaceService`.
    func restore(_ group: SnapGroup) {
        applyLayout(group, to: group.bounds, launchMissing: true)
    }

    /// Moves the whole group onto `screen`, preserving each member's
    /// relative shape — scaled to fit if the group's captured size is
    /// larger than the destination screen's visible area. Only affects
    /// CURRENTLY OPEN member windows (doesn't launch missing ones — moving
    /// what's there right now is the point of "move the group").
    func moveGroup(_ group: SnapGroup, to screen: NSScreen) {
        let vf = screen.visibleFrame
        let scale = min(1, min(vf.width / max(group.boundsWidth, 1), vf.height / max(group.boundsHeight, 1)))
        let newWidth = group.boundsWidth * scale
        let newHeight = group.boundsHeight * scale
        let newBounds = CGRect(x: vf.midX - newWidth / 2, y: vf.midY - newHeight / 2,
                                width: newWidth, height: newHeight)
        applyLayout(group, to: newBounds, launchMissing: false, screen: screen)
    }

    /// Resizes the group to fill the given screen entirely (its own default
    /// "Fit to Screen"), preserving the members' relative layout.
    func fitToScreen(_ group: SnapGroup, screen: NSScreen) {
        applyLayout(group, to: screen.visibleFrame, launchMissing: false, screen: screen)
    }

    private func applyLayout(_ group: SnapGroup, to bounds: CGRect, launchMissing: Bool, screen: NSScreen? = nil) {
        let current = windowService.fetchWindows()
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        for member in group.members {
            let frame = CGRect(x: bounds.minX + member.fraction.minX * bounds.width,
                                y: bounds.minY + member.fraction.minY * bounds.height,
                                width: member.fraction.width * bounds.width,
                                height: member.fraction.height * bounds.height)
            if let window = current.first(where: { $0.appName == member.appName && $0.windowTitle == member.title }),
               let targetScreen {
                windowService.applyFrame(frame, to: window, on: targetScreen)
            } else if launchMissing,
                      !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == member.bundleID }),
                      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: member.bundleID) {
                // Not running at all — launch it. (If it IS running but this
                // specific window isn't open/visible right now, there's no
                // generic "reopen that exact window" command to fall back
                // to — skipped rather than guessing.)
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    func minimizeGroup(_ group: SnapGroup) {
        for window in openWindows(for: group) { windowService.minimizeWindow(window) }
    }

    func restoreFromMinimize(_ group: SnapGroup) {
        // Re-resolve including minimized windows: fetchWindows() only lists
        // on-screen (unminimized) windows, so unminimize by app+title match
        // directly, the same lookup `WindowParkingService` uses.
        for member in group.members {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == member.bundleID }) else { continue }
            windowService.unminimizeWindow(bundlePID: app.processIdentifier, title: member.title)
        }
    }

    func hideGroup(_ group: SnapGroup) {
        for window in openWindows(for: group) { windowService.hideApp(window) }
    }

    func closeGroup(_ group: SnapGroup) {
        for window in openWindows(for: group) { windowService.closeWindow(window) }
    }

    /// Parks every currently-open member window (see `WindowParkingService`).
    func parkGroup(_ group: SnapGroup) {
        for window in openWindows(for: group) { WindowParkingService.shared.park(window) }
    }

    /// Restores every parked window whose captured app+title matches a
    /// member of this group.
    func restoreParkedGroup(_ group: SnapGroup) {
        let memberKeys = Set(group.members.map { "\($0.appName)|\($0.title)" })
        for parked in WindowParkingService.shared.parkedWindows
        where memberKeys.contains("\(parked.appName)|\(parked.title)") {
            WindowParkingService.shared.restore(parked)
        }
    }
}
