import Foundation

/// Optional, off-by-default Stage 1 provider that calls a user-configured
/// remote LLM endpoint over HTTPS. Off unless the user explicitly picks
/// "Remote model" in Settings AND supplies both an endpoint and an API key
/// — there is no bundled key, no default-on remote call anywhere in this
/// feature. Speaks the OpenAI-compatible `/chat/completions` JSON shape
/// (the de facto standard many providers — OpenAI itself, and OpenAI-
/// compatible proxies/local servers — already implement), so this needs no
/// vendor SDK dependency: a native `URLSession` POST is genuinely
/// sufficient here, unlike the on-device model which needs the actual
/// Foundation Models framework.
struct RemoteLLMProvider: NaturalLanguageProviding {
    let endpoint: URL
    let model: String
    let apiKey: String

    /// nil if the user hasn't configured both an endpoint/model AND saved
    /// a key — `NaturalLanguageService` treats that as "provider not
    /// available" and falls back to the rule-based one, same as an
    /// unavailable Apple Intelligence model.
    static func configured() -> RemoteLLMProvider? {
        guard AppSettings.remoteLLMEnabled,
              let url = URL(string: AppSettings.remoteLLMEndpoint), !AppSettings.remoteLLMEndpoint.isEmpty,
              let key = KeychainRemoteLLMKeyStore.load(), !key.isEmpty
        else { return nil }
        return RemoteLLMProvider(endpoint: url, model: AppSettings.remoteLLMModel, apiKey: key)
    }

    func parse(_ text: String, installedAppNames: [String]) async throws -> WorkspaceCommand {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": NLPromptBuilder.instructions(installedAppNames: installedAppNames)],
                ["role": "user", "content": NLPromptBuilder.prompt(for: text)],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NaturalLanguageError.invalidResponse
        }

        guard let content = Self.extractMessageContent(from: data),
              let command = NLPromptBuilder.decode(content)
        else { throw NaturalLanguageError.invalidResponse }
        return command
    }

    /// Pulls `choices[0].message.content` out of an OpenAI-shaped chat
    /// completion response — the one bit of vendor-specific parsing this
    /// needs, kept separate so it's easy to see exactly what shape is
    /// assumed.
    private static func extractMessageContent(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return nil }
        return content
    }
}
