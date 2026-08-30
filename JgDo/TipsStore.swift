import Foundation

/// Tracks which one-off tips have been dismissed, plus the global
/// "Don't show tips" opt-out. Shared by every tip in the app (clipboard
/// pinning, WorkflowInsights pair suggestion, SmartLayouts cards) so
/// there's one on/off switch, not several.
enum TipsStore {
    static let tipsEnabledKey = "tipsEnabled"
    static var tipsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: tipsEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: tipsEnabledKey) }
    }

    private static let dismissedKey = "dismissedTipIDs"
    private static var dismissed: Set<String> {
        get { Set((UserDefaults.standard.string(forKey: dismissedKey) ?? "").split(separator: ",").map(String.init)) }
        set { UserDefaults.standard.set(newValue.joined(separator: ","), forKey: dismissedKey) }
    }

    /// True if this tip should show right now.
    static func shouldShow(_ id: String) -> Bool {
        tipsEnabled && !dismissed.contains(id)
    }

    static func dismiss(_ id: String) {
        var d = dismissed
        d.insert(id)
        dismissed = d
    }
}
