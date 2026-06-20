import Foundation

/// Concrete Anthropic implementation of `AIProviderProtocol`.
///
/// Uses the Anthropic Messages API (`/v1/messages`).
/// Supports both streaming and non-streaming modes.
///
/// Key differences from OpenAI-compatible providers:
/// - Auth via `x-api-key` header (not Bearer token)
/// - Requires `anthropic-version` header
/// - System prompt is a top-level field, not a message
/// - `max_tokens` is required on every request
/// - Streaming uses typed SSE events (`content_block_delta`)
/// - Response content is an array of content blocks
final class AnthropicProvider: AIProviderProtocol, Sendable {

    private let apiKey: @Sendable () -> String?
    private let modelID: String
    private let client: AINetworkClient
    private let baseURL: URL
    private let apiPath: String

    /// - Parameters:
    ///   - apiKey: Closure returning the current API key.
    ///   - modelID: The Anthropic model identifier (e.g. "claude-sonnet-4-20250514").
    ///   - client: The network client for HTTP communication.
    ///   - baseURL: The Anthropic API base URL.
    ///   - apiPath: The messages endpoint path. Defaults to "/v1/messages".
    init(
        apiKey: @escaping @Sendable () -> String?,
        modelID: String,
        client: AINetworkClient = AINetworkClient(),
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        apiPath: String = "/v1/messages"
    ) {
        self.apiKey = apiKey
        self.modelID = modelID
        self.client = client
        self.baseURL = baseURL
        self.apiPath = apiPath
    }

    // MARK: - AIProviderProtocol

    func generateCompletion(
        userContent: String,
        systemPrompt: String,
        mode: String?
    ) async throws -> String {
        let messages: [[String: String]] = [
            ["role": "user", "content": userContent],
        ]

        let body: [String: Any] = [
            "model": modelID,
            "max_tokens": AILimits.maxResponseTokens,
            "system": systemPrompt,
            "messages": messages,
        ]

        let request = try buildRequest(body: body)
        let (data, _) = try await client.performRequest(request)

        return try parseCompletionResponse(data)
    }

    func streamChat(
        messages: [AIMessage],
        systemPrompt: String,
        mode: String?,
        contextTier: String?,
        explanationProfile: String?,
        language: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        var apiMessages: [[String: String]] = []
        for message in messages {
            // Anthropic does not accept "system" role in messages — it's a top-level field.
            guard message.role != .system else { continue }
            apiMessages.append([
                "role": message.role.rawValue,
                "content": message.content,
            ])
        }

        let body: [String: Any] = [
            "model": modelID,
            "max_tokens": AILimits.maxResponseTokens,
            "system": systemPrompt,
            "messages": apiMessages,
            "stream": true,
        ]

        let request = try buildRequest(body: body)
        let sseStream = try await client.performStreamingRequest(request)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var hasContent = false
                    for try await data in sseStream {
                        if let delta = try? self.parseStreamDelta(data) {
                            hasContent = true
                            continuation.yield(delta)
                        }
                    }
                    if !hasContent {
                        continuation.finish(throwing: AIProviderError.emptyResponse)
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func validateConnection() async throws {
        let messages: [[String: String]] = [
            ["role": "user", "content": "Say OK"],
        ]

        let body: [String: Any] = [
            "model": modelID,
            "max_tokens": AILimits.validationMaxTokens,
            "messages": messages,
        ]

        let request = try buildRequest(body: body)
        let (data, _) = try await client.performRequest(request)

        _ = try parseCompletionResponse(data)
    }

    // MARK: - Request Building

    private func buildRequest(body: [String: Any]) throws -> URLRequest {
        guard let key = apiKey(), !key.isEmpty else {
            throw AIProviderError.apiKeyMissing
        }

        let url = baseURL.appendingPathComponent(apiPath)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return request
    }

    // MARK: - Response Parsing

    /// Parse a non-streaming Messages API response.
    ///
    /// Expected shape:
    /// ```json
    /// {
    ///   "content": [
    ///     { "type": "text", "text": "..." }
    ///   ],
    ///   "stop_reason": "end_turn"
    /// }
    /// ```
    private func parseCompletionResponse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String
        else {
            // Check for Anthropic error response format.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let errorMessage = error["message"] as? String
            {
                throw AIProviderError.providerError(statusCode: 0, message: errorMessage)
            }
            throw AIProviderError.invalidResponse(
                detail: "Could not parse Anthropic response"
            )
        }
        return text
    }

    /// Parse a single SSE data payload from a streaming Messages API response.
    ///
    /// Anthropic streams multiple event types. We only extract text from
    /// `content_block_delta` events:
    /// ```json
    /// {
    ///   "type": "content_block_delta",
    ///   "delta": { "type": "text_delta", "text": "..." }
    /// }
    /// ```
    ///
    /// Returns `nil` for non-delta events (message_start, content_block_start,
    /// content_block_stop, message_stop, ping).
    private func parseStreamDelta(_ data: Data) throws -> String? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              type == "content_block_delta",
              let delta = json["delta"] as? [String: Any],
              let text = delta["text"] as? String
        else {
            return nil
        }
        return text
    }
}
