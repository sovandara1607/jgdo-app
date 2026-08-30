import Foundation

/// Shared prompt template + response decoding for the two LLM-backed
/// providers (`AppleIntelligenceProvider`, `RemoteLLMProvider`) — both ask
/// their model for the exact same JSON shape and decode it the same way,
/// so that logic lives once instead of twice.
enum NLPromptBuilder {
    /// System/instructions text: tells the model exactly what JSON shape
    /// to produce and, critically, which app names and layout values are
    /// actually valid — the model is grounded to real data, not free to
    /// invent an app that isn't installed or a layout that doesn't exist.
    static func instructions(installedAppNames: [String]) -> String {
        let layouts = WindowLayout.allCases.map(\.rawValue).joined(separator: "\", \"")
        // Cap the app list length in the prompt itself — a Mac with an
        // enormous /Applications folder shouldn't blow the context window;
        // `WorkspaceCommandExecutor` re-validates against the FULL list
        // afterward regardless, so truncating here only affects what the
        // model can reference, never what's actually allowed to run.
        let names = installedAppNames.prefix(300).joined(separator: ", ")
        return """
        You convert one short instruction about arranging Mac app windows into JSON, and ONLY JSON — no prose, no markdown code fences, no explanation before or after it.

        Output must match exactly this shape:
        {"placements":[{"appName":"<name>","layout":"<layout>","screenIndex":null}],"appsToClose":["<name>"],"summary":"<one short line describing what you did>"}

        Rules:
        - "appName" must be one of these installed apps, matched by closest name: \(names)
        - "layout" must be exactly one of: "\(layouts)"
        - "screenIndex" is null unless the instruction names a specific display (0 = main display, 1 = second, …)
        - Only include "appsToClose" entries when the instruction explicitly says to close/quit that app — never infer a close.
        - If you can't confidently map the instruction to any app/layout, return {"placements":[],"appsToClose":[],"summary":""}.
        - Never include any field other than the ones shown above.
        """
    }

    static func prompt(for text: String) -> String {
        "Instruction: \(text)"
    }

    /// Tolerant decode: strips a leading/trailing markdown code fence if
    /// the model added one despite instructions not to, then decodes the
    /// first `{...}` object found. Returns nil (never throws) so callers
    /// can treat "the model didn't cooperate" the same as "network/model
    /// unavailable" — both just fall back to `RuleBasedProvider`.
    static func decode(_ raw: String) -> WorkspaceCommand? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.drop(while: { $0 != "\n" }).dropFirst()
                .description
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let jsonSlice = text[start...end]
        guard let data = jsonSlice.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WorkspaceCommand.self, from: data)
    }
}
