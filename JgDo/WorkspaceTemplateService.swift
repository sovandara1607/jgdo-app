import AppKit

/// Resolves a `WorkspaceTemplate`'s role-based slots against whatever's
/// actually installed, launches missing apps, and places them.
@MainActor
final class WorkspaceTemplateService {
    static let shared = WorkspaceTemplateService()
    private init() {}

    /// True if at least one candidate for every non-park slot is installed —
    /// used to gray out templates that can't run on this Mac at all.
    func isAvailable(_ template: WorkspaceTemplate) -> Bool {
        template.slots.allSatisfy { slot in
            slot.candidateBundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        }
    }

    /// Absolute screen rects for the preview schematic — pure geometry, no
    /// launching. Skips park slots (nothing to draw).
    func previewFrames(for template: WorkspaceTemplate, on screen: NSScreen) -> [CGRect] {
        let vf = screen.visibleFrame
        return template.slots.filter { !$0.park }.map { slot in
            CGRect(x: vf.minX + slot.fraction.minX * vf.width,
                   y: vf.minY + slot.fraction.minY * vf.height,
                   width: slot.fraction.width * vf.width,
                   height: slot.fraction.height * vf.height)
        }
    }

    /// Launches/finds each slot's app and places it. Best-effort — a role
    /// with nothing installed is simply skipped.
    func apply(_ template: WorkspaceTemplate) async {
        guard let screen = NSScreen.main else { return }
        let windowService = WindowManagerService()

        for slot in template.slots {
            guard let bundleID = bestCandidate(for: slot),
                  let app = await AppLaunchWaiter.launchOrFind(bundleID: bundleID) else { continue }

            if slot.park {
                if let window = windowService.fetchWindows().first(where: { $0.pid == app.processIdentifier }) {
                    windowService.minimizeWindow(window)
                }
                continue
            }
            guard let window = windowService.fetchWindows().first(where: { $0.pid == app.processIdentifier }) else { continue }
            let vf = screen.visibleFrame
            let frame = CGRect(x: vf.minX + slot.fraction.minX * vf.width,
                                y: vf.minY + slot.fraction.minY * vf.height,
                                width: slot.fraction.width * vf.width,
                                height: slot.fraction.height * vf.height)
            windowService.applyFrame(frame, to: window, on: screen)
        }

        if template.focusOthers, !FocusModeService.shared.isActive {
            _ = FocusModeService.shared.toggle()
        }
        ActionToastCenter.shared.show("\(template.name) Template Applied", icon: template.symbolName)
    }

    /// Prefers an already-running candidate (avoids relaunching something
    /// the user already has open), else the first installed one.
    private func bestCandidate(for slot: WorkspaceTemplate.Slot) -> String? {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        if let match = slot.candidateBundleIDs.first(where: { running.contains($0) }) { return match }
        return slot.candidateBundleIDs.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }
}
