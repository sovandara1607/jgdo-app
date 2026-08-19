import AppKit
import ApplicationServices

/// Best-effort background-tab discovery for Window Search. Uses the
/// *public*, documented `kAXTabsAttribute` ("AXTabs") — not a browser-
/// specific hack — which Safari supports reliably; Chrome/Chromium-family
/// browsers expose it inconsistently across versions. Where a browser
/// doesn't expose it (or isn't a browser at all), this returns an empty
/// list and callers fall back to plain window-title search, exactly as
/// specified: "gracefully fall back to window-title searching when
/// browser-tab information is unavailable."
enum BrowserTabService {
    /// Bundle IDs worth even trying `AXTabs` on — skips the AX round-trip
    /// for the common case (a non-browser window has no tabs anyway).
    private static let knownBrowserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "org.mozilla.firefox", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser",
    ]

    static func isKnownBrowser(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return knownBrowserBundleIDs.contains(bundleID)
    }

    /// One open tab: its title and the specific `AXUIElement` to `AXPress`
    /// on pick, so selecting it switches to that tab (not just focuses
    /// whichever tab happens to be active).
    struct Tab {
        let title: String
        let axElement: AXUIElement
    }

    static func tabs(of axWindow: AXUIElement) -> [Tab] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXTabsAttribute as CFString, &ref) == .success,
              let tabElements = ref as? [AXUIElement] else { return [] }
        return tabElements.compactMap { tab in
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(tab, kAXTitleAttribute as CFString, &titleRef)
            guard let title = titleRef as? String, !title.isEmpty else { return nil }
            return Tab(title: title, axElement: tab)
        }
    }

    /// Switches to this tab. Safari's tab elements respond to a plain
    /// `AXPress`; if that has no effect on a given browser, the window
    /// still gets focused by the normal pick flow — this is best-effort on
    /// top of that, never the only way a pick "succeeds."
    static func activate(_ axElement: AXUIElement) {
        AXUIElementPerformAction(axElement, kAXPressAction as CFString)
    }
}
