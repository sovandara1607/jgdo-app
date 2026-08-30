import Foundation

/// The ONLY data structure that crosses from "parsed natural-language
/// text" to "actually moves windows". Every provider — `RuleBasedProvider`,
/// `AppleIntelligenceProvider`, the optional `RemoteLLMProvider` — produces
/// exactly this shape (see `NaturalLanguageProviding`); nothing downstream
/// cares which one ran. Deliberately plain data: there is no field here
/// that could express "run a shell command" or anything beyond "place this
/// named app at this layout" / "close this named app" — the safety
/// boundary is architectural, not a runtime check bolted on afterward.
struct WorkspaceCommand: Codable, Equatable {
    struct Placement: Codable, Equatable {
        var appName: String
        var layout: WindowLayout
        /// Index into `NSScreen.screens`, or nil for "whichever screen the
        /// window/app is already on". Validated against the actual screen
        /// count before use — see `WorkspaceCommandExecutor.validate`.
        var screenIndex: Int?

        init(appName: String, layout: WindowLayout, screenIndex: Int? = nil) {
            self.appName = appName
            self.layout = layout
            self.screenIndex = screenIndex
        }
    }

    var placements: [Placement] = []
    /// App names to close/quit as part of this command — only ever
    /// populated when the instruction explicitly asked for it (e.g. "close
    /// Slack and open Xcode"); a provider must never infer a close the user
    /// didn't state.
    var appsToClose: [String] = []
    /// A short human-readable description of what was understood, e.g.
    /// "Slack → Left Half, Xcode → Right Half" — shown verbatim in the
    /// preview UI so the user can sanity-check intent before anything
    /// moves, regardless of which provider produced it.
    var summary: String = ""

    /// True when nothing could be parsed at all — the UI shows a "couldn't
    /// understand that" state instead of an empty Apply button.
    var isEmpty: Bool { placements.isEmpty && appsToClose.isEmpty }
}
