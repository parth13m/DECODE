import Foundation
import Testing
@testable import Decode

/// All AI-layer tests grouped under one serialized suite to prevent
/// cross-test interference on MockURLProtocol's shared static state.
@Suite(.serialized)
struct AILayerTests {

    // MARK: - AINetworkClient Tests

    @Suite struct NetworkClient {

        private func makeClient(
            maxRetries: Int = 3,
            baseDelay: TimeInterval = 0.01,
            maxJitter: TimeInterval = 0.01
        ) -> AINetworkClient {
            let session = MockURLProtocol.makeMockSession()
            let config = RetryConfiguration(
                maxRetries: maxRetries,
                baseDelay: baseDelay,
                maxJitter: maxJitter
            )
            return AINetworkClient(session: session, retryConfig: config)
        }

        private func makeRequest() -> URLRequest {
            URLRequest(url: URL(string: "https://api.test.com/v1/completions")!)
        }

        @Test func successfulRequest() async throws {
            MockURLProtocol.reset()
            let client = makeClient()

            MockURLProtocol.requestHandler = { _ in
                let r = HTTPURLResponse(url: URL(string: "https://api.test.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return ("hello".data(using: .utf8)!, r)
            }

            let (data, response) = try await client.performRequest(makeRequest())
            #expect(String(data: data, encoding: .utf8) == "hello")
            #expect(response.statusCode == 200)
        }

        @Test func invalidAPIKeyThrows() async throws {
            MockURLProtocol.reset()
            let client = makeClient()

            MockURLProtocol.requestHandler = { _ in
                let r = HTTPURLResponse(url: URL(string: "https://api.test.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (Data(), r)
            }

            do {
                _ = try await client.performRequest(makeRequest())
                Issue.record("Should have thrown")
            } catch is AIProviderError {
                // expected
            }
        }

        @Test func clientErrorThrows() async throws {
            MockURLProtocol.reset()
            let client = makeClient()

            MockURLProtocol.requestHandler = { _ in
                let r = HTTPURLResponse(url: URL(string: "https://api.test.com")!, statusCode: 400, httpVersion: nil, headerFields: nil)!
                return ("Bad request".data(using: .utf8)!, r)
            }

            do {
                _ = try await client.performRequest(makeRequest())
                Issue.record("Should have thrown")
            } catch let error as AIProviderError {
                guard case .providerError(let code, _) = error else {
                    Issue.record("Expected providerError, got \(error)")
                    return
                }
                #expect(code == 400)
            }
        }

        @Test func serverErrorExhaustsRetries() async throws {
            MockURLProtocol.reset()
            let client = makeClient(maxRetries: 2)

            MockURLProtocol.requestHandler = { _ in
                let r = HTTPURLResponse(url: URL(string: "https://api.test.com")!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (Data(), r)
            }

            do {
                _ = try await client.performRequest(makeRequest())
                Issue.record("Should have thrown")
            } catch let error as AIProviderError {
                guard case .retriesExhausted = error else {
                    Issue.record("Expected retriesExhausted, got \(error)")
                    return
                }
            }
        }

        @Test func serverErrorRetryThenSuccess() async throws {
            MockURLProtocol.reset()
            let client = makeClient(maxRetries: 3)
            nonisolated(unsafe) var callCount = 0

            MockURLProtocol.requestHandler = { _ in
                callCount += 1
                if callCount < 3 {
                    let r = HTTPURLResponse(url: URL(string: "https://api.test.com")!, statusCode: 503, httpVersion: nil, headerFields: nil)!
                    return (Data(), r)
                } else {
                    let r = HTTPURLResponse(url: URL(string: "https://api.test.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return ("success".data(using: .utf8)!, r)
                }
            }

            let (data, _) = try await client.performRequest(makeRequest())
            #expect(String(data: data, encoding: .utf8) == "success")
        }

        @Test func backoffIsExponential() {
            let client = makeClient()
            #expect(client.computeBackoff(attempt: 0) >= 1.0)
            #expect(client.computeBackoff(attempt: 1) >= 2.0)
            #expect(client.computeBackoff(attempt: 2) >= 4.0)
        }

        @Test func backoffCapsAt60() {
            let client = makeClient()
            #expect(client.computeBackoff(attempt: 10) <= 61.0)
        }

        @Test func headersArePreserved() async throws {
            MockURLProtocol.reset()
            let client = makeClient()
            nonisolated(unsafe) var capturedAuth: String?

            MockURLProtocol.requestHandler = { request in
                capturedAuth = request.value(forHTTPHeaderField: "Authorization")
                let r = HTTPURLResponse(url: URL(string: "https://api.test.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(), r)
            }

            var request = makeRequest()
            request.setValue("Bearer my-key", forHTTPHeaderField: "Authorization")
            _ = try await client.performRequest(request)
            #expect(capturedAuth == "Bearer my-key")
        }
    }

    // MARK: - OpenAICompatibleProvider Tests

    @Suite struct Provider {

        private func completionJSON(content: String) -> Data {
            """
            {"choices":[{"message":{"role":"assistant","content":"\(content)"},"finish_reason":"stop"}]}
            """.data(using: .utf8)!
        }

        private func makeProvider(apiKey: String = "sk-test", modelID: String = "gpt-4o-mini") -> OpenAICompatibleProvider {
            let session = MockURLProtocol.makeMockSession()
            let client = AINetworkClient(
                session: session,
                retryConfig: RetryConfiguration(maxRetries: 0, baseDelay: 0, maxJitter: 0)
            )
            return OpenAICompatibleProvider(
                apiKey: { apiKey },
                modelID: modelID,
                client: client,
                baseURL: URL(string: "https://api.openai.com")!
            )
        }

        private func ok(_ data: Data) -> (Data, HTTPURLResponse) {
            let r = HTTPURLResponse(url: URL(string: "https://api.openai.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, r)
        }

        @Test func completionReturnsContent() async throws {
            MockURLProtocol.reset()
            let provider = makeProvider()
            nonisolated(unsafe) var capturedBody: [String: Any]?

            MockURLProtocol.requestHandler = { request in
                if let data = MockURLProtocol.bodyData(from: request) {
                    capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
                return self.ok(self.completionJSON(content: "Summary here."))
            }

            let result = try await provider.generateCompletion(userContent: "Summarize", systemPrompt: "Be concise.")
            #expect(result == "Summary here.")
            #expect(capturedBody?["model"] as? String == "gpt-4o-mini")
            #expect(capturedBody?["stream"] as? Bool == false)
        }

        @Test func completionThrowsOnEmptyKey() async {
            MockURLProtocol.reset()
            let provider = makeProvider(apiKey: "")

            await #expect(throws: AIProviderError.self) {
                try await provider.generateCompletion(userContent: "t", systemPrompt: "t")
            }
        }

        @Test func completionThrowsOn401() async {
            MockURLProtocol.reset()
            let provider = makeProvider()

            MockURLProtocol.requestHandler = { _ in
                let r = HTTPURLResponse(url: URL(string: "https://api.openai.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (Data(), r)
            }

            await #expect(throws: AIProviderError.self) {
                try await provider.generateCompletion(userContent: "t", systemPrompt: "t")
            }
        }

        @Test func validateConnectionUsesMinimalTokens() async throws {
            MockURLProtocol.reset()
            let provider = makeProvider()
            nonisolated(unsafe) var capturedMaxTokens: Int?

            MockURLProtocol.requestHandler = { request in
                if let data = MockURLProtocol.bodyData(from: request) {
                    let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    capturedMaxTokens = body?["max_tokens"] as? Int
                }
                return self.ok(self.completionJSON(content: "OK"))
            }

            try await provider.validateConnection()
            #expect(capturedMaxTokens == 5)
        }

        @Test func systemPromptIsFirst() async throws {
            MockURLProtocol.reset()
            let provider = makeProvider()
            nonisolated(unsafe) var capturedMessages: [[String: String]]?

            MockURLProtocol.requestHandler = { request in
                if let data = MockURLProtocol.bodyData(from: request) {
                    let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    capturedMessages = body?["messages"] as? [[String: String]]
                }
                return self.ok(self.completionJSON(content: "ok"))
            }

            _ = try await provider.generateCompletion(userContent: "hi", systemPrompt: "Be helpful.")
            #expect(capturedMessages?[0]["role"] == "system")
            #expect(capturedMessages?[0]["content"] == "Be helpful.")
        }

        @Test func authHeaderContainsKey() async throws {
            MockURLProtocol.reset()
            let provider = makeProvider(apiKey: "sk-secret")
            nonisolated(unsafe) var capturedAuth: String?

            MockURLProtocol.requestHandler = { request in
                capturedAuth = request.value(forHTTPHeaderField: "Authorization")
                return self.ok(self.completionJSON(content: "ok"))
            }

            _ = try await provider.generateCompletion(userContent: "t", systemPrompt: "t")
            #expect(capturedAuth == "Bearer sk-secret")
        }

        @Test func streamChatFormatsMessages() async throws {
            MockURLProtocol.reset()
            let provider = makeProvider()
            nonisolated(unsafe) var capturedBody: [String: Any]?

            MockURLProtocol.requestHandler = { request in
                if let data = MockURLProtocol.bodyData(from: request) {
                    capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
                let r = HTTPURLResponse(url: URL(string: "https://api.openai.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(), r)
            }

            let messages = [
                AIMessage(role: .user, content: "What?"),
                AIMessage(role: .assistant, content: "It sorts."),
            ]
            let stream = try await provider.streamChat(messages: messages, systemPrompt: "Help.")
            for try await _ in stream {}

            let msgs = capturedBody?["messages"] as? [[String: String]]
            #expect(msgs?.count == 3) // system + 2
            #expect(msgs?[0]["role"] == "system")
            #expect(msgs?[1]["content"] == "What?")
            #expect(msgs?[2]["content"] == "It sorts.")
            #expect(capturedBody?["stream"] as? Bool == true)
        }

        @Test func errorBodyIsParsed() async throws {
            MockURLProtocol.reset()
            let provider = makeProvider()

            MockURLProtocol.requestHandler = { _ in
                let body = """
                {"error":{"message":"Quota exceeded","type":"insufficient_quota"}}
                """.data(using: .utf8)!
                return self.ok(body)
            }

            do {
                _ = try await provider.generateCompletion(userContent: "t", systemPrompt: "t")
                Issue.record("Should have thrown")
            } catch let error as AIProviderError {
                if case .providerError(_, let msg) = error {
                    #expect(msg.contains("Quota"))
                }
            }
        }
    }
}
