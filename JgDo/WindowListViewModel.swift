import Foundation
import AppKit
import Observation

@Observable
final class WindowListViewModel {
    var windows: [WindowInfo] = []
    var searchText: String = ""
    var isAccessibilityGranted: Bool = false
    var selectedWindowID: UUID? = nil
    var pinnedAppNames: Set<String> = []

    private let service = WindowManagerService()
    private var timer: Timer?

    init() { loadPins() }

    // MARK: Derived

    var filteredWindows: [WindowInfo] {
        guard !searchText.isEmpty else { return windows }
        return windows.filter {
            $0.appName.localizedCaseInsensitiveContains(searchText) ||
            $0.windowTitle.localizedCaseInsensitiveContains(searchText)
        }
    }

    var groupedWindows: [(appName: String, icon: NSImage?, windows: [WindowInfo], isPinned: Bool)] {
        var groups: [(appName: String, icon: NSImage?, windows: [WindowInfo], isPinned: Bool)] = []
        var indexMap: [String: Int] = [:]
        for win in filteredWindows {
            if let i = indexMap[win.appName] {
                groups[i].windows.append(win)
            } else {
                let pinned = pinnedAppNames.contains(win.appName)
                indexMap[win.appName] = groups.count
                groups.append((win.appName, win.icon, [win], pinned))
            }
        }
        return groups.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.appName.localizedCompare($1.appName) == .orderedAscending
        }
    }

    var flatWindows: [WindowInfo] { groupedWindows.flatMap(\.windows) }

    // MARK: Refresh

    func startRefresh() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stopRefresh() { timer?.invalidate(); timer = nil }

    func refresh() {
        isAccessibilityGranted = service.isAccessibilityGranted
        guard isAccessibilityGranted else { return }
        let fresh = service.fetchWindows()
        // Diff: only update if content changed (avoids SwiftUI churn)
        if fresh.map(\.windowID) != windows.map(\.windowID) {
            windows = fresh
            // Keep selection valid
            if let id = selectedWindowID, !fresh.contains(where: { $0.id == id }) {
                selectedWindowID = nil
            }
        }
    }

    func requestPermission() { service.requestAccessibilityPermission() }

    // MARK: Keyboard navigation

    func selectNext() {
        let flat = flatWindows
        guard !flat.isEmpty else { return }
        if let cur = selectedWindowID, let idx = flat.firstIndex(where: { $0.id == cur }) {
            selectedWindowID = flat[min(idx + 1, flat.count - 1)].id
        } else {
            selectedWindowID = flat.first?.id
        }
    }

    func selectPrevious() {
        let flat = flatWindows
        guard !flat.isEmpty else { return }
        if let cur = selectedWindowID, let idx = flat.firstIndex(where: { $0.id == cur }) {
            selectedWindowID = flat[max(idx - 1, 0)].id
        } else {
            selectedWindowID = flat.last?.id
        }
    }

    func focusSelected() {
        guard let id = selectedWindowID,
              let win = flatWindows.first(where: { $0.id == id }) else { return }
        focus(win)
    }

    // MARK: Window actions

    func focus(_ window: WindowInfo) { service.focusWindow(window) }
    func minimize(_ window: WindowInfo) { service.minimizeWindow(window) }
    func close(_ window: WindowInfo) { service.closeWindow(window); refresh() }
    func hideApp(_ window: WindowInfo) { service.hideApp(window) }

    // MARK: Pinning

    func togglePin(appName: String) {
        if pinnedAppNames.contains(appName) { pinnedAppNames.remove(appName) }
        else { pinnedAppNames.insert(appName) }
        savePins()
    }

    private func loadPins() {
        pinnedAppNames = Set(UserDefaults.standard.stringArray(forKey: "pinnedApps") ?? [])
    }

    private func savePins() {
        UserDefaults.standard.set(Array(pinnedAppNames), forKey: "pinnedApps")
    }
}
