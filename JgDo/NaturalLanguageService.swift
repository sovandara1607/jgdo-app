import AppKit
import os

/// Which `NaturalLanguageProviding` implementation the user has selected in
/// Settings. `ruleBased` is the default — the feature works fully offline
/// and on macOS 14 without it; the other two are opportunistic upgrades a
/// user can explicitly opt into.
enum NaturalLanguageProviderKind: String, CaseIterable, Identifiable {
    case ruleBased, appleIntelligence, remote
    var id: String { rawValue }

    var label: String {
        switch self {
        case .ruleBased:         return "Built-in (rule-based, offline)"
        case .appleIntelligence: return "Apple Intelligence (on-device)"
        case .remote:            return "Remote model (your API key)"
        }
    }
}

/// Facade over Stage 1 parsing — resolves which provider to actually run
/// (falling back to `RuleBasedProvider` if the user's chosen one isn't
/// available or fails) and never throws to its caller, since the preview
/// UI always needs SOME result to show, even a "couldn't understand that"
/// empty one.
@MainActor
final class NaturalLanguageService {
    static let shared = NaturalLanguageService()
    private init() {}

    /// All installed apps' display names — the only "grounding" data any
    /// provider is given about what exists on this Mac. Recomputed per
    /// call rather than cached: this runs once per user submission, not in
    /// a hot loop, and app installs/uninstalls shouldn't need a cache
    /// invalidation story here.
    private func installedAppNames() -> [String] {
        CommandPaletteState.installedApps.map { $0.name }
    }

    func parse(_ text: String) async -> WorkspaceCommand {
        let names = installedAppNames()
        let kind = AppSettings.nlWorkspaceProvider

        let primary: NaturalLanguageProviding?
        switch kind {
        case .ruleBased:
            primary = nil   // falls straight to the RuleBasedProvider below
        case .appleIntelligence:
            if #available(macOS 26.0, *) {
                primary = AppleIntelligenceProvider()
            } else {
                primary = nil
            }
        case .remote:
            primary = RemoteLLMProvider.configured()
        }

        if let primary {
            if let result = try? await primary.parse(text, installedAppNames: names), !result.isEmpty {
                return result
            }
            AppLog.general.notice("Natural-language provider '\(kind.rawValue, privacy: .public)' returned nothing usable — falling back to the built-in parser.")
        }
        return RuleBasedProvider.parse(text, installedAppNames: names)
    }
}
