import Foundation
import ComposableArchitecture

// MARK: - Token Usage

struct AITokenUsage: Equatable {
    let inputTokens: Int
    let outputTokens: Int

    static let zero = AITokenUsage(inputTokens: 0, outputTokens: 0)

    /// Estimated cost in USD using claude-sonnet-4-6 pricing ($3/MTok in, $15/MTok out)
    var estimatedCost: Double {
        Double(inputTokens) * 3.0 / 1_000_000 + Double(outputTokens) * 15.0 / 1_000_000
    }

    var totalTokens: Int { inputTokens + outputTokens }
}

// MARK: - ClaudeClient

struct ClaudeClient {
    var chat: @Sendable (String, String, [ChatMessage]) async throws -> (String, AITokenUsage)
    // (apiKey, systemPrompt, messageHistory) -> (responseText, usage)
}

extension ClaudeClient: DependencyKey {
    static var liveValue: ClaudeClient {
        ClaudeClient(
            chat: { apiKey, systemPrompt, history in
                let messages = history.map { msg -> [String: String] in
                    ["role": msg.role == .user ? "user" : "assistant",
                     "content": msg.content]
                }
                return try await sendChatRequest(apiKey: apiKey, system: systemPrompt, messages: messages)
            }
        )
    }
}

private func sendChatRequest(apiKey: String, system: String, messages: [[String: String]]) async throws -> (String, AITokenUsage) {
    guard !apiKey.isEmpty else { throw AIError.noAPIKey }

    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

    let body: [String: Any] = [
        "model": "claude-sonnet-4-6",
        "max_tokens": 2048,
        "system": system,
        "messages": messages
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
    guard http.statusCode == 200 else {
        let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
        throw AIError.apiError(http.statusCode, msg)
    }

    let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)
    let text = decoded.content.first?.text ?? ""
    let usage = AITokenUsage(
        inputTokens: decoded.usage.inputTokens,
        outputTokens: decoded.usage.outputTokens
    )
    return (text, usage)
}

private struct ClaudeResponse: Decodable {
    struct Content: Decodable { let text: String }
    struct Usage: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
    let content: [Content]
    let usage: Usage
}

enum AIError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No Claude API key. Add it in Settings."
        case .invalidResponse: return "Invalid response from Claude API."
        case .apiError(let code, let msg): return "API error \(code): \(msg)"
        }
    }
}

extension DependencyValues {
    var claudeClient: ClaudeClient {
        get { self[ClaudeClient.self] }
        set { self[ClaudeClient.self] = newValue }
    }
}
