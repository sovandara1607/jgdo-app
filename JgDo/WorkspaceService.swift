import AppKit
import SwiftData
import ApplicationServices

/// Saves and restores named window arrangements ("workspaces").
/// Frames are stored in AppKit coordinates for the whole desktop, so a
/// workspace saved on a multi-monitor setup restores across all screens.
@Observable
final class WorkspaceService {
    static let shared = WorkspaceService()

    private(set) var workspaces: [Workspace] = []
    private let windowService = WindowManagerService()

    private init() {
        reload()
    }

    func reload() {
        let ctx = Persistence.shared.context
        workspaces = (try? ctx.fetch(FetchDescriptor<Workspace>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
    }

    // MARK: Capture

    /// Snapshot every visible standard window into a new workspace.
    @discardableResult
    func saveCurrentLayout(named name: String) -> Workspace? {
        let windows = windowService.fetchWindows()
        guard !windows.isEmpty else { return nil }

        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let running = NSWorkspace.shared.runningApplications
        let workspace = Workspace(name: name)

        for info in windows {
            guard let app = running.first(where: { $0.processIdentifier == info.pid }),
                  let bundleID = app.bundleIdentifier else { continue }
            // CG coords (top-left origin) → AppKit coords (bottom-left origin).
            let appKit = CGRect(x: info.bounds.minX,
                                y: mainH - info.bounds.maxY,
                                width: info.bounds.width,
                                height: info.bounds.height)
            let entry = WorkspaceWindow(bundleID: bundleID,
                                        appName: info.appName,
                                        title: info.windowTitle,
                                        frame: appKit)
            entry.workspace = workspace
            workspace.windows.append(entry)
        }
        guard !workspace.windows.isEmpty else { return nil }

        Persistence.shared.context.insert(workspace)
        Persistence.shared.save()
        reload()
        return workspace
    }

    // MARK: Restore

    /// One window's saved placement, detached from the SwiftData model so it
    /// can cross into launch-completion closures safely.
    private struct SavedPlacement {
        let frame: CGRect
        let title: String?
    }

    /// Reapply a saved workspace: launch missing apps, then place each app's
    /// windows at their saved frames.
    func restore(_ workspace: Workspace) {
        workspace.lastUsedAt = Date()
        Persistence.shared.save()

        // Saved placements per app, in z-order (front first).
        var placementsByBundle: [String: [SavedPlacement]] = [:]
        for w in workspace.windows {
            placementsByBundle[w.bundleID, default: []]
                .append(SavedPlacement(frame: w.frame, title: w.title))
        }

        for (bundleID, placements) in placementsByBundle {
            if let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == bundleID }) {
                place(app: app, placements: placements)
            } else if let url = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
                    guard let app else { return }
                    // Give the app a moment to create its first window.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.place(app: app, placements: placements)
                    }
                }
            }
        }
    }

    /// Place an app's windows: match each saved placement to a live AX window
    /// by title first (AX window order is not the saved z-order, so blind
    /// zipping shuffles frames between same-app windows), then pair whatever
    /// is left positionally.
    private func place(app: NSRunningApplication, placements: [SavedPlacement]) {
        app.unhide()
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString,
                                            &ref) == .success,
              let axWindows = ref as? [AXUIElement], !axWindows.isEmpty else { return }

        var unclaimed = axWindows
        var unmatched: [SavedPlacement] = []
        for placement in placements {
            if let title = placement.title, !title.isEmpty,
               let idx = unclaimed.firstIndex(where: { axTitle(of: $0) == title }) {
                apply(frame: placement.frame, to: unclaimed.remove(at: idx))
            } else {
                unmatched.append(placement)
            }
        }
        for (placement, axWin) in zip(unmatched, unclaimed) {
            apply(frame: placement.frame, to: axWin)
        }
    }

    private func axTitle(of axWindow: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString,
                                            &ref) == .success else { return nil }
        return ref as? String
    }

    private func apply(frame: CGRect, to axWin: AXUIElement) {
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        var origin = CGPoint(x: frame.minX, y: mainH - frame.maxY)
        var size = CGSize(width: frame.width, height: frame.height)
        if let pv = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, pv)
        }
        if let sv = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sv)
        }
    }

    // MARK: Management

    func delete(_ workspace: Workspace) {
        Persistence.shared.context.delete(workspace)
        Persistence.shared.save()
        reload()
    }

    func rename(_ workspace: Workspace, to name: String) {
        workspace.name = name
        Persistence.shared.save()
        reload()
    }
}
