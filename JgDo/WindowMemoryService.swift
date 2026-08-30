import AppKit
import ApplicationServices
import os

/// Per-app window position/size memory, opt-in per app. When enabled for an
/// app, its focused window's frame is captured the moment focus leaves it
/// (`capture`, hooked to `NSWorkspace.didDeactivateApplicationNotification`)
/// and reapplied once — not on every switch back, which would fight the
/// user re-moving the window mid-session — the next time that app's
/// *process* activates (`applyIfNeeded`, hooked to
/// `didActivateApplicationNotification`, gated on process identity so a
/// relaunch gets the memory again but a plain alt-tab back doesn't).
///
/// Persisted as plain UserDefaults JSON (bundle ID keyed) rather than
/// SwiftData — this is small, flat, key-value data with no relationships,
/// so a model/schema would be pure overhead.
@Observable
final class WindowMemoryService {
    static let shared = WindowMemoryService()

    private struct Entry: Codable {
        var appName: String
        var x: Double, y: Double, width: Double, height: Double
        var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    private(set) var enabledBundleIDs: Set<String> = []
    private var entries: [String: Entry] = [:]
    /// Processes memory has already been applied to this launch — a plain
    /// activation (alt-tab back) must NOT re-snap the window.
    private var appliedPIDs = Set<pid_t>()

    private static let enabledKey = "windowMemoryEnabledBundleIDs"
    private static let entriesKey = "windowMemoryEntries"

    private init() { load() }

    func isEnabled(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        return enabledBundleIDs.contains(id)
    }

    /// Names of apps currently being remembered, for a Settings list.
    var rememberedApps: [(bundleID: String, name: String)] {
        enabledBundleIDs.map { ($0, entries[$0]?.appName ?? $0) }.sorted { $0.name < $1.name }
    }

    /// Enables/disables remembering for `app` and returns the new state.
    @discardableResult
    func toggle(for app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        if enabledBundleIDs.contains(id) {
            enabledBundleIDs.remove(id)
            entries.removeValue(forKey: id)
        } else {
            enabledBundleIDs.insert(id)
            capture(app)   // seed immediately so it's not empty until next switch-away
        }
        persist()
        return enabledBundleIDs.contains(id)
    }

    func forget(bundleID: String) {
        enabledBundleIDs.remove(bundleID)
        entries.removeValue(forKey: bundleID)
        persist()
    }

    /// Saves `app`'s focused window's current frame, if remembering is
    /// enabled for it. Called as the app loses focus.
    func capture(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, enabledBundleIDs.contains(id) else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref, let cgFrame = WindowManagerService.axFrame(of: ref as! AXUIElement) else { return }
        let appKit = CoordinateSpace.appKit(fromCG: cgFrame)
        entries[id] = Entry(appName: app.localizedName ?? id, x: appKit.minX, y: appKit.minY,
                             width: appKit.width, height: appKit.height)
        persist()
    }

    /// Applies the remembered frame to `app`'s focused window — once per
    /// process lifetime.
    func applyIfNeeded(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, enabledBundleIDs.contains(id),
              !appliedPIDs.contains(app.processIdentifier),
              let entry = entries[id] else { return }
        appliedPIDs.insert(app.processIdentifier)

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref else { return }
        let axWindow = ref as! AXUIElement
        let cgFrame = CoordinateSpace.cg(fromAppKit: entry.frame)
        WindowManagerService.setAXFrame(cgFrame, of: axWindow)
    }

    private func load() {
        if let ids = UserDefaults.standard.array(forKey: Self.enabledKey) as? [String] {
            enabledBundleIDs = Set(ids)
        }
        if let data = UserDefaults.standard.data(forKey: Self.entriesKey) {
            do {
                entries = try JSONDecoder().decode([String: Entry].self, from: data)
            } catch {
                AppLog.general.error("Couldn't decode remembered window positions: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func persist() {
        UserDefaults.standard.set(Array(enabledBundleIDs), forKey: Self.enabledKey)
        do {
            let data = try JSONEncoder().encode(entries)
            UserDefaults.standard.set(data, forKey: Self.entriesKey)
        } catch {
            AppLog.general.error("Couldn't save remembered window positions: \(error.localizedDescription, privacy: .public)")
        }
    }
}
