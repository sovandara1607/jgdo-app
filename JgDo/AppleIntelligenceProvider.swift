import Foundation
import FoundationModels

/// On-device Apple Intelligence parsing via the Foundation Models
/// framework — `SystemLanguageModel`/`LanguageModelSession`, gated to
/// macOS 26.0+ (the framework's actual availability floor; earlier plan
/// notes said 15.1, which predates the real ship date). Opportunistic: if
/// unavailable, `NaturalLanguageService` silently falls back to
/// `RuleBasedProvider` — nothing in the app requires this to work.
///
/// Deliberately avoids the `@Generable` macro/structured-output path here.
/// Asking the model to reply with plain JSON text (which `String` already
/// conforms to `Generable` for, no macro needed) and decoding that
/// ourselves keeps this provider's shape identical to `RemoteLLMProvider`'s
/// (same "prompt in, JSON text out, `JSONDecoder` does the rest" plumbing)
/// rather than needing two entirely different integration styles for two
/// providers that do conceptually the same job.
@available(macOS 26.0, *)
struct AppleIntelligenceProvider: NaturalLanguageProviding {
    func parse(_ text: String, installedAppNames: [String]) async throws -> WorkspaceCommand {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { throw NaturalLanguageError.modelUnavailable }

        let session = LanguageModelSession(
            model: model,
            instructions: NLPromptBuilder.instructions(installedAppNames: installedAppNames)
        )
        let response = try await session.respond(to: NLPromptBuilder.prompt(for: text))
        guard let command = NLPromptBuilder.decode(response.content) else {
            throw NaturalLanguageError.invalidResponse
        }
        return command
    }
}
