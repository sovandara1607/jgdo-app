import Foundation
import CoreGraphics

/// A built-in, app-agnostic workspace starter — unlike `Workspace` (saved
/// from specific running apps), this describes *roles* ("code editor",
/// "browser") with candidate bundle IDs, resolved to whatever's actually
/// installed at apply time.
struct WorkspaceTemplate: Identifiable {
    struct Slot {
        let roleLabel: String
        let candidateBundleIDs: [String]
        /// Fraction (0...1) of the screen's visible frame, AppKit bottom-left
        /// origin — same convention as `LayoutSlot`.
        let fraction: CGRect
        /// True = minimize/park instead of placing (e.g. Messages during a meeting).
        var park: Bool = false
    }

    let id: String
    let name: String
    let symbolName: String
    let slots: [Slot]
    /// Hides every other app's windows once applied (Focus Mode) — for
    /// "Writing", where distraction-free is the point.
    var focusOthers: Bool = false

    static let builtIns: [WorkspaceTemplate] = [
        WorkspaceTemplate(
            id: "coding", name: "Coding", symbolName: "chevron.left.forwardslash.chevron.right",
            slots: [
                Slot(roleLabel: "Code Editor", candidateBundleIDs: codeEditors,
                     fraction: CGRect(x: 0, y: 0, width: 0.6, height: 1.0)),
                Slot(roleLabel: "Browser", candidateBundleIDs: browsers,
                     fraction: CGRect(x: 0.6, y: 0.5, width: 0.4, height: 0.5)),
                Slot(roleLabel: "Terminal", candidateBundleIDs: terminals,
                     fraction: CGRect(x: 0.6, y: 0.0, width: 0.4, height: 0.5)),
            ]
        ),
        WorkspaceTemplate(
            id: "study", name: "Study", symbolName: "book",
            slots: [
                Slot(roleLabel: "Browser", candidateBundleIDs: browsers,
                     fraction: CGRect(x: 0, y: 0, width: 0.6, height: 1.0)),
                Slot(roleLabel: "Notes", candidateBundleIDs: notesApps,
                     fraction: CGRect(x: 0.6, y: 0, width: 0.4, height: 1.0)),
            ]
        ),
        WorkspaceTemplate(
            id: "meeting", name: "Meeting", symbolName: "video",
            slots: [
                Slot(roleLabel: "Video Call", candidateBundleIDs: videoCallApps,
                     fraction: CGRect(x: 0, y: 0, width: 0.7, height: 1.0)),
                Slot(roleLabel: "Notes", candidateBundleIDs: notesApps,
                     fraction: CGRect(x: 0.7, y: 0, width: 0.3, height: 1.0)),
                Slot(roleLabel: "Messages", candidateBundleIDs: messagingApps,
                     fraction: .zero, park: true),
            ]
        ),
        WorkspaceTemplate(
            id: "writing", name: "Writing", symbolName: "pencil.and.outline",
            slots: [
                Slot(roleLabel: "Editor", candidateBundleIDs: writingApps,
                     fraction: CGRect(x: 0.15, y: 0.1, width: 0.55, height: 0.8)),
                Slot(roleLabel: "Browser", candidateBundleIDs: browsers,
                     fraction: CGRect(x: 0.72, y: 0.1, width: 0.26, height: 0.8)),
            ],
            focusOthers: true
        ),
    ]

    // Candidate lists, most-preferred first — the resolver picks whichever
    // is already running, else the first one that's installed.
    private static let codeEditors = ["com.microsoft.VSCode", "com.apple.dt.Xcode", "com.sublimetext.4", "com.apple.TextEdit"]
    private static let browsers = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox"]
    private static let terminals = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable"]
    private static let notesApps = ["com.apple.Notes", "md.obsidian", "notion.id"]
    private static let videoCallApps = ["us.zoom.xos", "com.apple.FaceTime", "com.microsoft.teams2"]
    private static let messagingApps = ["com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "ru.keepcoder.Telegram"]
    private static let writingApps = ["com.apple.TextEdit", "md.obsidian", "net.shinyfrog.bear", "notion.id"]
}
