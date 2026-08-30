import Foundation

/// Stage 1 of Natural-Language Workspace Creation: turns free text into a
/// `WorkspaceCommand`. Implementations never see anything beyond the text
/// and a list of installed app names — no filesystem, no process spawning,
/// no shell — and can only ever hand back the narrow `WorkspaceCommand`
/// shape (see its doc comment). `NaturalLanguageService` is what picks
/// which implementation actually runs.
protocol NaturalLanguageProviding {
    func parse(_ text: String, installedAppNames: [String]) async throws -> WorkspaceCommand
}

enum NaturalLanguageError: Error {
    case modelUnavailable
    case invalidResponse
}

// MARK: - Rule-based provider (default, zero dependencies, always available)

/// Regex/keyword parsing for the common phrasings this feature's brief
/// itself uses as examples — "Put Slack on the left and Xcode on the
/// right", "Split screen with Terminal and Safari", "Maximize Notes",
/// "Center Notes". This is intentionally simple pattern matching, not
/// general NLP: it recognizes layout keywords and installed-app-name
/// substrings and pairs the two by proximity in the sentence. It's the
/// default provider (works on macOS 14, no network, no model download) —
/// `AppleIntelligenceProvider`/`RemoteLLMProvider` are opportunistic
/// upgrades over this, not replacements for it.
struct RuleBasedProvider: NaturalLanguageProviding {
    func parse(_ text: String, installedAppNames: [String]) async throws -> WorkspaceCommand {
        Self.parse(text, installedAppNames: installedAppNames)
    }

    /// Longest-phrase-first so "top left" matches before the bare "top"/
    /// "left" keywords would otherwise steal it. Not `private`:
    /// `CommandPaletteState` reuses this exact table for the Command
    /// Palette's own layout-keyword matching (`>` -free typing like "snap
    /// left"/"tile left"/"window left" — each already matches via plain
    /// substring containment against the bare "left" entry below, so those
    /// aliases need no separate list) rather than maintaining a second,
    /// possibly-drifting copy of the same alias data.
    static let keywordLayouts: [(phrase: String, layout: WindowLayout)] = [
        ("top left", .topLeft), ("upper left", .topLeft), ("top-left", .topLeft),
        ("top right", .topRight), ("upper right", .topRight), ("top-right", .topRight),
        ("bottom left", .bottomLeft), ("lower left", .bottomLeft), ("bottom-left", .bottomLeft),
        ("bottom right", .bottomRight), ("lower right", .bottomRight), ("bottom-right", .bottomRight),
        ("left half", .leftHalf), ("right half", .rightHalf),
        ("top half", .topHalf), ("bottom half", .bottomHalf),
        ("full screen", .maximize), ("fullscreen", .maximize), ("full-screen", .maximize),
        ("maximize", .maximize), ("maximized", .maximize),
        ("center", .center), ("centre", .center), ("centered", .center), ("centred", .center),
        ("left", .leftHalf), ("right", .rightHalf), ("top", .topHalf), ("bottom", .bottomHalf),
    ]

    /// Pure, unit-testable: given lowercased text and the set of installed
    /// app names, finds every (appName, layout) pairing it can, plus any
    /// "close X" instructions. No AppKit, no live app list — those are
    /// supplied by the caller so this is exercisable with fixtures.
    static func parse(_ text: String, installedAppNames: [String]) -> WorkspaceCommand {
        let lower = text.lowercased()

        // "close X" / "quit X" — scan before layout matching so a closed
        // app's name doesn't also get treated as a placement target.
        var closeTargets: [String] = []
        var remaining = lower
        for verb in ["close ", "quit "] {
            var searchRange = remaining.startIndex..<remaining.endIndex
            while let verbRange = remaining.range(of: verb, range: searchRange) {
                let after = verbRange.upperBound
                if let app = firstAppName(in: String(remaining[after...]), candidates: installedAppNames) {
                    closeTargets.append(app)
                }
                searchRange = verbRange.upperBound..<remaining.endIndex
            }
        }
        // Strip "close X"/"quit X" spans out of the working text so those
        // app mentions don't ALSO get picked up as placement targets below.
        for target in closeTargets {
            remaining = remaining.replacingOccurrences(of: "close \(target.lowercased())", with: " ")
            remaining = remaining.replacingOccurrences(of: "quit \(target.lowercased())", with: " ")
        }

        // Find every installed app name mentioned, with its character range.
        let appMentions = installedAppNames.compactMap { name -> (name: String, range: Range<String.Index>)? in
            guard let range = remaining.range(of: name.lowercased()) else { return nil }
            return (name, range)
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }

        // Find every layout keyword mentioned, with its character range —
        // first match per phrase only (repeats don't add information).
        var keywordMentions: [(range: Range<String.Index>, layout: WindowLayout)] = []
        for (phrase, layout) in keywordLayouts {
            guard let range = remaining.range(of: phrase) else { continue }
            // Skip if this range is already covered by an earlier (longer)
            // match — e.g. "top left" already claimed, don't also match "top".
            guard !keywordMentions.contains(where: { $0.range.overlaps(range) }) else { continue }
            keywordMentions.append((range, layout))
        }

        var placements: [WorkspaceCommand.Placement] = []

        if appMentions.count >= 2 && keywordMentions.isEmpty
            && (lower.contains("split") || lower.contains("side by side") || lower.contains(" and ")) {
            // "Split screen with Slack and Xcode" / "Slack and Xcode side
            // by side" — no per-app keyword, just an implied left/right
            // split in mention order.
            placements.append(.init(appName: appMentions[0].name, layout: .leftHalf))
            placements.append(.init(appName: appMentions[1].name, layout: .rightHalf))
        } else if appMentions.count == keywordMentions.count && !appMentions.isEmpty {
            // Equal counts — pair the Nth app (by position) with the Nth
            // layout keyword (by position), in text order. This handles
            // both "App KEYWORD … App KEYWORD" (keyword follows its app,
            // e.g. "Slack on the left") and "KEYWORD App" (keyword
            // precedes it, e.g. "Maximize Notes") uniformly — nearest-
            // neighbor distance alone can't: a keyword belonging to app N
            // can sit numerically closer to app N+1 than to its own app
            // (e.g. "…on the left and Xcode…" — "left" is closer to
            // "Xcode" than "right" is).
            let sortedApps = appMentions.sorted { $0.range.lowerBound < $1.range.lowerBound }
            let sortedKeywords = keywordMentions.sorted { $0.range.lowerBound < $1.range.lowerBound }
            for (mention, keyword) in zip(sortedApps, sortedKeywords) {
                placements.append(.init(appName: mention.name, layout: keyword.layout))
            }
        } else {
            // Mismatched counts — no clean 1:1 reading, fall back to
            // pairing each app with whichever keyword is nearest to it.
            for mention in appMentions {
                guard let nearest = keywordMentions.min(by: {
                    distance(mention.range, $0.range, in: remaining) < distance(mention.range, $1.range, in: remaining)
                }) else { continue }
                placements.append(.init(appName: mention.name, layout: nearest.layout))
            }
        }

        var command = WorkspaceCommand()
        command.placements = placements
        command.appsToClose = closeTargets
        command.summary = summary(placements: placements, closeTargets: closeTargets)
        return command
    }

    private static func firstAppName(in text: String, candidates: [String]) -> String? {
        candidates
            .compactMap { name -> (String, Range<String.Index>)? in
                text.range(of: name.lowercased()).map { (name, $0) }
            }
            .min { $0.1.lowerBound < $1.1.lowerBound }
            .map(\.0)
    }

    /// Character distance between two ranges within `text` — used to find
    /// the layout keyword closest to a given app mention. Zero if they
    /// overlap; otherwise the gap between whichever range comes first and
    /// the start of the one that follows it.
    private static func distance(_ a: Range<String.Index>, _ b: Range<String.Index>, in text: String) -> Int {
        if a.overlaps(b) { return 0 }
        if a.upperBound <= b.lowerBound {
            return text.distance(from: a.upperBound, to: b.lowerBound)
        }
        return text.distance(from: b.upperBound, to: a.lowerBound)
    }

    private static func summary(placements: [WorkspaceCommand.Placement], closeTargets: [String]) -> String {
        var parts: [String] = placements.map { "\($0.appName) → \($0.layout.rawValue)" }
        if !closeTargets.isEmpty {
            parts.append("Close \(closeTargets.joined(separator: ", "))")
        }
        return parts.isEmpty ? "" : parts.joined(separator: ", ")
    }
}
