import Foundation

/// AI provider that routes requests through the Decode backend gateway.
///
/// Replaces direct API key management — the backend owns the Anthropic key
/// and the client authenticates via its Decode access token (Bearer).
///
/// Implements ``AIProviderProtocol`` so all coordinators (Selection, Screenshot,
/// Session) work without modification.
struct DecodeGatewayProvider: AIProviderProtocol, Sendable {

    /// Closure that returns the current access token from Keychain.
    /// Called on each request so token changes are picked up immediately.
    private let accessToken: @Sendable () -> String?

    /// URL session for HTTP requests.
    private let session: URLSession

    /// Request timeout in seconds.
    private static let timeout: TimeInterval = 120

    init(
        accessToken: @escaping @Sendable () -> String?,
        session: URLSession = .shared
    ) {
        self.accessToken = accessToken
        self.session = session
    }

    // MARK: - AIProviderProtocol

    func generateCompletion(
        userContent: String,
        systemPrompt: String,
        mode: String?
    ) async throws -> String {
        let messages = [AIMessage(role: .user, content: userContent)]
        let response = try await callGateway(messages: messages, systemPrompt: systemPrompt, mode: mode)
        return response
    }

    func streamChat(
        messages: [AIMessage],
        systemPrompt: String,
        mode: String?,
        contextTier: String?,
        explanationProfile: String?,
        language: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let token = accessToken(), !token.isEmpty else {
            throw AIProviderError.notAuthenticated
        }

        let body = GatewayRequest(
            messages: messages.map { GatewayMessage(role: $0.role.rawValue, content: $0.content) },
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            mode: mode,
            contextTier: contextTier,
            explanationProfile: explanationProfile,
            language: language
        )
        let encodedBody = try JSONEncoder().encode(body)

        // Try the streaming endpoint first; fall back to non-streaming if unavailable.
        let streamURL = DecodeConfig.backendBaseURL.appendingPathComponent("api/gateway/chat/stream")
        var request = URLRequest(url: streamURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = encodedBody

        // Check if the streaming endpoint is reachable by initiating the request.
        // URLSession.bytes gives us the HTTP status before consuming the body.
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw AIProviderError.timeout
        } catch {
            throw AIProviderError.networkError(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse(detail: "Not an HTTP response")
        }

        // If the streaming endpoint is not available (old backend), fall back.
        if httpResponse.statusCode == 404 || httpResponse.statusCode == 405 {
            #if DEBUG
            print("[DEBUG GatewayProvider] streaming endpoint unavailable (\(httpResponse.statusCode)), falling back to /chat")
            #endif
            return try await streamChatFallback(
                encodedBody: encodedBody,
                token: token
            )
        }

        // Map non-200 status codes to errors.
        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw AIProviderError.sessionExpired
        case 403:
            throw AIProviderError.accountDisabled
        case 422:
            throw AIProviderError.invalidResponse(detail: "Invalid request format")
        case 429:
            throw AIProviderError.rateLimited(retryAfter: nil)
        default:
            throw AIProviderError.serviceUnavailable
        }

        // Return a stream that parses SSE events from the response body.
        let capturedSession = session
        _ = capturedSession // retain session for lifetime of stream

        // DIAG: capture request start time for client-side diagnostics
        let diagRequestStart = CFAbsoluteTimeGetCurrent()

        return AsyncThrowingStream { continuation in
            let task = Task {
                // DIAG: client SSE diagnostics
                var diagFirstSSETime: CFAbsoluteTime?
                var diagSSECount = 0
                var diagYieldCount = 0
                var diagTotalBytes = 0

                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }

                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard let data = jsonStr.data(using: .utf8) else { continue }

                        guard let event = try? JSONDecoder().decode(SSEEvent.self, from: data) else {
                            continue
                        }

                        switch event.type {
                        case "token":
                            if let content = event.content {
                                diagSSECount += 1
                                diagTotalBytes += content.utf8.count
                                if diagFirstSSETime == nil {
                                    diagFirstSSETime = CFAbsoluteTimeGetCurrent()
                                    #if DEBUG
                                    let firstMs = (diagFirstSSETime! - diagRequestStart) * 1000
                                    print("[DIAG_CLIENT] first_sse_received_ms=\(String(format: "%.0f", firstMs))")
                                    #endif
                                }
                                diagYieldCount += 1
                                continuation.yield(content)
                            }
                        case "done":
                            // DIAG: summary
                            #if DEBUG
                            let totalMs = (CFAbsoluteTimeGetCurrent() - diagRequestStart) * 1000
                            let avgBytes = diagSSECount > 0 ? Double(diagTotalBytes) / Double(diagSSECount) : 0
                            print("[DIAG_CLIENT] total_ms=\(String(format: "%.0f", totalMs)) sse_events=\(diagSSECount) yields=\(diagYieldCount) total_bytes=\(diagTotalBytes) avg_chunk_bytes=\(String(format: "%.1f", avgBytes))")
                            #endif
                            // Usage is logged server-side; client just finishes.
                            continuation.finish()
                            return
                        case "error":
                            let message = event.message ?? "AI service unavailable"
                            continuation.finish(throwing: AIProviderError.invalidResponse(detail: message))
                            return
                        default:
                            break
                        }
                    }

                    // Stream ended without a "done" event — finish gracefully.
                    if !Task.isCancelled {
                        // DIAG: stream ended without done
                        #if DEBUG
                        let totalMs = (CFAbsoluteTimeGetCurrent() - diagRequestStart) * 1000
                        print("[DIAG_CLIENT] stream_ended_no_done total_ms=\(String(format: "%.0f", totalMs)) sse_events=\(diagSSECount) yields=\(diagYieldCount)")
                        #endif
                        continuation.finish()
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIProviderError.networkError(underlying: error))
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
        guard let token = accessToken(), !token.isEmpty else {
            throw AIProviderError.notAuthenticated
        }

        #if DEBUG
        let tStart = CFAbsoluteTimeGetCurrent()
        #endif

        let url = DecodeConfig.backendBaseURL.appendingPathComponent("api/gateway/vision")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let base64ImageString = imageData.base64EncodedString()

        #if DEBUG
        let tBase64Done = CFAbsoluteTimeGetCurrent()
        #endif

        let body = VisionGatewayRequest(
            imageData: base64ImageString,
            prompt: prompt,
            mode: mode
        )
        request.httpBody = try JSONEncoder().encode(body)

        #if DEBUG
        let tJsonDone = CFAbsoluteTimeGetCurrent()
        let bodySize = request.httpBody?.count ?? 0
        #endif

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw AIProviderError.timeout
        } catch {
            throw AIProviderError.networkError(underlying: error)
        }

        #if DEBUG
        let tNetworkDone = CFAbsoluteTimeGetCurrent()
        #endif

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse(detail: "Not an HTTP response")
        }

        switch httpResponse.statusCode {
        case 200:
            let decoded = try JSONDecoder().decode(GatewayResponse.self, from: data)

            #if DEBUG
            let tParseDone = CFAbsoluteTimeGetCurrent()
            print("[LATENCY] ── Gateway Vision Breakdown ──")
            print("[LATENCY]   Base64 encoding:    \(String(format: "%.1f", (tBase64Done - tStart) * 1000))ms (\(imageData.count) bytes → \(base64ImageString.count) chars)")
            print("[LATENCY]   JSON serialization:  \(String(format: "%.1f", (tJsonDone - tBase64Done) * 1000))ms (\(bodySize) bytes body)")
            print("[LATENCY]   Network round-trip:  \(String(format: "%.0f", (tNetworkDone - tJsonDone) * 1000))ms (upload + backend + Anthropic + download)")
            print("[LATENCY]   Response parsing:    \(String(format: "%.1f", (tParseDone - tNetworkDone) * 1000))ms (\(data.count) bytes response)")
            print("[LATENCY]   Gateway total:       \(String(format: "%.0f", (tParseDone - tStart) * 1000))ms")
            #endif

            guard !decoded.content.isEmpty else {
                throw AIProviderError.emptyResponse
            }
            return decoded.content
        case 401:
            throw AIProviderError.sessionExpired
        case 403:
            throw AIProviderError.accountDisabled
        case 502:
            throw AIProviderError.serviceUnavailable
        default:
            throw AIProviderError.serviceUnavailable
        }
    }

    func validateConnection() async throws {
        // Validate by sending a minimal request to the gateway.
        let messages = [AIMessage(role: .user, content: "hi")]
        _ = try await callGateway(messages: messages, systemPrompt: "Reply with OK only.", mode: nil)
    }

    // MARK: - Streaming Fallback

    /// Fall back to the non-streaming /chat endpoint when /chat/stream
    /// is unavailable (e.g. old backend version during deployment).
    private func streamChatFallback(
        encodedBody: Data,
        token: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        let chatURL = DecodeConfig.backendBaseURL.appendingPathComponent("api/gateway/chat")
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = encodedBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw AIProviderError.timeout
        } catch {
            throw AIProviderError.networkError(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse(detail: "Not an HTTP response")
        }

        switch httpResponse.statusCode {
        case 200:
            let decoded = try JSONDecoder().decode(GatewayResponse.self, from: data)
            guard !decoded.content.isEmpty else {
                throw AIProviderError.emptyResponse
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(decoded.content)
                continuation.finish()
            }
        case 401:
            throw AIProviderError.sessionExpired
        case 403:
            throw AIProviderError.accountDisabled
        case 422:
            throw AIProviderError.invalidResponse(detail: "Invalid request format")
        case 429:
            throw AIProviderError.rateLimited(retryAfter: nil)
        case 502:
            throw AIProviderError.serviceUnavailable
        default:
            throw AIProviderError.serviceUnavailable
        }
    }

    // MARK: - Non-Streaming Gateway Communication

    private func callGateway(
        messages: [AIMessage],
        systemPrompt: String,
        mode: String?,
        contextTier: String? = nil
    ) async throws -> String {
        guard let token = accessToken(), !token.isEmpty else {
            throw AIProviderError.notAuthenticated
        }

        let url = DecodeConfig.backendBaseURL.appendingPathComponent("api/gateway/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body = GatewayRequest(
            messages: messages.map { GatewayMessage(role: $0.role.rawValue, content: $0.content) },
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            mode: mode,
            contextTier: contextTier,
            explanationProfile: nil,
            language: nil
        )
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw AIProviderError.timeout
        } catch {
            throw AIProviderError.networkError(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse(detail: "Not an HTTP response")
        }

        switch httpResponse.statusCode {
        case 200:
            let decoded = try JSONDecoder().decode(GatewayResponse.self, from: data)
            guard !decoded.content.isEmpty else {
                throw AIProviderError.emptyResponse
            }
            return decoded.content

        case 401:
            throw AIProviderError.sessionExpired

        case 403:
            throw AIProviderError.accountDisabled

        case 422:
            throw AIProviderError.invalidResponse(detail: "Invalid request format")

        case 429:
            throw AIProviderError.rateLimited(retryAfter: nil)

        case 502:
            throw AIProviderError.serviceUnavailable

        default:
            throw AIProviderError.serviceUnavailable
        }
    }

}

// MARK: - Request/Response Models

private struct GatewayMessage: Encodable {
    let role: String
    let content: String
}

private struct GatewayRequest: Encodable {
    let messages: [GatewayMessage]
    let systemPrompt: String?
    let mode: String?
    let contextTier: String?
    let explanationProfile: String?
    let language: String?

    enum CodingKeys: String, CodingKey {
        case messages
        case systemPrompt = "system_prompt"
        case mode
        case contextTier = "context_tier"
        case explanationProfile = "explanation_profile"
        case language
    }
}

private struct VisionGatewayRequest: Encodable {
    let imageData: String
    let prompt: String
    let mode: String?

    enum CodingKeys: String, CodingKey {
        case imageData = "image_data"
        case prompt
        case mode
    }
}

private struct GatewayResponse: Decodable {
    let content: String
}

// MARK: - SSE Event Model

/// Decode-owned SSE event format. Decoded from `data:` lines in the
/// streaming response from `/api/gateway/chat/stream`.
private struct SSEEvent: Decodable {
    let type: String
    /// Token content — present when `type == "token"`.
    let content: String?
    /// Error message — present when `type == "error"`.
    let message: String?
    /// Token usage — present when `type == "done"`. Not consumed by
    /// the client (analytics are logged server-side).
    let usage: SSEUsage?
}

private struct SSEUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let promptCharacterCount: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptCharacterCount = "prompt_character_count"
    }
}
