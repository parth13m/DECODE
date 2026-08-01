import Foundation

/// Provider for any API that implements the OpenAI Chat Completions format.
///
/// Covers OpenAI, OpenRouter, Groq, Together, DeepSeek, and any custom
/// endpoint that speaks the same protocol (`/v1/chat/completions` with
/// `Bearer` auth and SSE streaming).
final class OpenAICompatibleProvider: AIProviderProtocol, Sendable {

    private let apiKey: @Sendable () -> String?
    private let modelID: String
    private let client: AINetworkClient
    private let baseURL: URL
    private let apiPath: String

    /// - Parameters:
    ///   - apiKey: Closure returning the current API key. Using a closure
    ///     allows the key to be updated at runtime without recreating the provider.
    ///   - modelID: The model identifier to send in requests (e.g. "gpt-4o").
    ///   - client: The network client for HTTP communication.
    ///   - baseURL: The provider's base URL (e.g. "https://api.openai.com").
    ///   - apiPath: The chat completions path. Defaults to "/v1/chat/completions".
    init(
        apiKey: @escaping @Sendable () -> String?,
        modelID: String,
        client: AINetworkClient = AINetworkClient(),
        baseURL: URL,
        apiPath: String = "/v1/chat/completions"
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
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userContent],
        ]

        let body: [String: Any] = [
            "model": modelID,
            "messages": messages,
            "max_tokens": AILimits.maxResponseTokens,
            "stream": false,
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
        var apiMessages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
        ]
        for message in messages {
            apiMessages.append([
                "role": message.role.rawValue,
                "content": message.content,
            ])
        }

        let body: [String: Any] = [
            "model": modelID,
            "messages": apiMessages,
            "max_tokens": AILimits.maxResponseTokens,
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

    func generateVisionCompletion(
        imageData: Data,
        prompt: String,
        mode: String?
    ) async throws -> String {
        let base64Image = imageData.base64EncodedString()

        // OpenAI-compatible vision format: multimodal content blocks.
        let userContent: [[String: Any]] = [
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64Image)"]],
            ["type": "text", "text": prompt],
        ]

        let messages: [[String: Any]] = [
            ["role": "user", "content": userContent],
        ]

        let body: [String: Any] = [
            "model": modelID,
            "messages": messages,
            "max_tokens": AILimits.maxVisionResponseTokens,
            "stream": false,
        ]

        let request = try buildRequest(body: body)
        let (data, _) = try await client.performRequest(request)

        return try parseCompletionResponse(data)
    }

    func validateConnection() async throws {
        let messages: [[String: String]] = [
            ["role": "user", "content": "Say OK"],
        ]

        let body: [String: Any] = [
            "model": modelID,
            "messages": messages,
            "max_tokens": AILimits.validationMaxTokens,
            "stream": false,
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

        let url = Self.buildEndpointURL(base: baseURL, apiPath: apiPath)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return request
    }

    // MARK: - Response Parsing

    private func parseCompletionResponse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let errorMessage = error["message"] as? String
            {
                throw AIProviderError.providerError(statusCode: 0, message: errorMessage)
            }
            throw AIProviderError.invalidResponse(
                detail: "Could not parse completion response"
            )
        }
        return content
    }

    private func parseStreamDelta(_ data: Data) throws -> String? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any]
        else {
            return nil
        }
        return delta["content"] as? String
    }

    // MARK: - URL Construction

    /// Build the full endpoint URL, handling the case where the base URL's path
    /// overlaps with the beginning of `apiPath`.
    ///
    /// For example, if a user enters `https://api.groq.com/openai/v1` as their
    /// base URL and `apiPath` is `/v1/chat/completions`, naive path appending
    /// produces `/openai/v1/v1/chat/completions`. This method detects the `/v1`
    /// overlap and produces `/openai/v1/chat/completions` instead.
    static func buildEndpointURL(base: URL, apiPath: String) -> URL {
        let basePath = base.path
        let normalizedPath = apiPath.hasPrefix("/") ? apiPath : "/\(apiPath)"

        // Find the longest suffix of basePath that matches a prefix of apiPath.
        let maxOverlap = min(basePath.count, normalizedPath.count)
        for overlapLen in stride(from: maxOverlap, through: 1, by: -1) {
            let baseSuffix = String(basePath.suffix(overlapLen))
            let pathPrefix = String(normalizedPath.prefix(overlapLen))
            if baseSuffix == pathPrefix {
                let remainder = String(normalizedPath.dropFirst(overlapLen))
                if remainder.isEmpty { return base }
                return base.appendingPathComponent(remainder)
            }
        }

        // No overlap — append the full path.
        return base.appendingPathComponent(normalizedPath)
    }
}
