import Foundation
import Testing
@testable import Decode

/// Tests for the gateway error classification pipeline.
///
/// Validates that backend ``error_type`` values are correctly mapped to
/// ``AIProviderError`` cases, and that the user-facing messages are accurate.
@Suite(.serialized)
struct GatewayErrorMappingTests {

    // MARK: - Helpers

    private func makeProvider() -> DecodeGatewayProvider {
        let session = MockURLProtocol.makeMockSession()
        return DecodeGatewayProvider(
            accessToken: { "test-token" },
            session: session
        )
    }

    /// Configure MockURLProtocol to return an HTTP error with the given status
    /// code and a JSON body containing ``error_type``.
    private func mockHTTPError(statusCode: Int, errorType: String) {
        MockURLProtocol.requestHandler = { _ in
            let body = try! JSONSerialization.data(withJSONObject: [
                "detail": ["message": "AI service unavailable", "error_type": errorType]
            ])
            let response = HTTPURLResponse(
                url: URL(string: "https://test.decode.com")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (body, response)
        }
    }

    /// Configure MockURLProtocol to return an HTTP error with a legacy string
    /// detail (no ``error_type`` field — backwards compatibility).
    private func mockLegacyHTTPError(statusCode: Int) {
        MockURLProtocol.requestHandler = { _ in
            let body = try! JSONSerialization.data(withJSONObject: [
                "detail": "AI service unavailable"
            ])
            let response = HTTPURLResponse(
                url: URL(string: "https://test.decode.com")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (body, response)
        }
    }

    /// Configure MockURLProtocol to return a specific HTTP status with no body.
    private func mockHTTPStatus(_ statusCode: Int) {
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://test.decode.com")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
    }

    /// Call generateCompletion and expect a specific AIProviderError case.
    private func expectError(
        _ expectedCase: String,
        provider: DecodeGatewayProvider,
        file: String = #file,
        line: Int = #line
    ) async {
        do {
            _ = try await provider.generateCompletion(
                userContent: "test",
                systemPrompt: "test",
                mode: nil
            )
            Issue.record("Expected error but succeeded", sourceLocation: SourceLocation(fileID: file, filePath: file, line: line, column: 0))
        } catch let error as AIProviderError {
            let mirror = Mirror(reflecting: error)
            let caseName = mirror.children.first?.label ?? String(describing: error)
            // Use string comparison to check the error case matches
            let errorString = String(describing: error)
            #expect(errorString.contains(expectedCase) || caseName == expectedCase,
                    "Expected \(expectedCase) but got \(errorString)")
        } catch {
            Issue.record("Expected AIProviderError but got \(type(of: error)): \(error)",
                        sourceLocation: SourceLocation(fileID: file, filePath: file, line: line, column: 0))
        }
    }

    // MARK: - Error Type Mapping via HTTP Path

    @Test func serverErrorMapsToServiceUnavailable() async throws {
        MockURLProtocol.reset()
        mockHTTPError(statusCode: 502, errorType: "server_error")
        let provider = makeProvider()

        do {
            _ = try await provider.generateCompletion(userContent: "test", systemPrompt: "test", mode: nil)
            Issue.record("Expected error")
        } catch let error as AIProviderError {
            guard case .serviceUnavailable = error else {
                Issue.record("Expected .serviceUnavailable but got \(error)")
                return
            }
        }
    }

    @Test func streamErrorMapsToServiceUnavailable() async throws {
        MockURLProtocol.reset()
        mockHTTPError(statusCode: 502, errorType: "stream_error")
        let provider = makeProvider()

        do {
            _ = try await provider.generateCompletion(userContent: "test", systemPrompt: "test", mode: nil)
            Issue.record("Expected error")
        } catch let error as AIProviderError {
            guard case .serviceUnavailable = error else {
                Issue.record("Expected .serviceUnavailable but got \(error)")
                return
            }
        }
    }

    @Test func networkErrorFromBackendMapsToServiceUnavailable() async throws {
        MockURLProtocol.reset()
        mockHTTPError(statusCode: 502, errorType: "network_error")
        let provider = makeProvider()

        do {
            _ = try await provider.generateCompletion(userContent: "test", systemPrompt: "test", mode: nil)
            Issue.record("Expected error")
        } catch let error as AIProviderError {
            guard case .serviceUnavailable = error else {
                Issue.record("Expected .serviceUnavailable but got \(error)")
                return
            }
        }
    }

    @Test func rateLimitMapsToRateLimited() async throws {
        MockURLProtocol.reset()
        mockHTTPError(statusCode: 502, errorType: "rate_limit")
        let provider = makeProvider()

        do {
            _ = try await provider.generateCompletion(userContent: "test", systemPrompt: "test", mode: nil)
            Issue.record("Expected error")
        } catch let error as AIProviderError {
            guard case .rateLimited = error else {
                Issue.record("Expected .rateLimited but got \(error)")
                return
            }
        }
    }

    @Test func timeoutFromBackendMapsToTimeout() async throws {
        MockURLProtocol.reset()
        mockHTTPError(statusCode: 502, errorType: "timeout")
        let provider = makeProvider()

        do {
            _ = try await provider.generateCompletion(userContent: "test", systemPrompt: "test", mode: nil)
            Issue.record("Expected error")
        } catch let error as AIProviderError {
            guard case .timeout = error else {
                Issue.record("Expected .timeout but got \(error)")
                return
            }
        }
    }

    @Test func authErrorMapsToServiceError() async throws {
        MockURLProtocol.reset()
        mockHTTPError(statusCode: 502, errorType: "auth_error")
        let provider = makeProvider()

        do {
            _ = try await provider.generateCompletion(userContent: "test", systemPrompt: "test", mode: nil)
            Issue.record("Expected error")
        } catch let error as AIProviderError {
            guard case .serviceError = error else {
                Issue.record("Expected .serviceError but got \(error)")
                return
            }
        }
    }

    @Test func apiErrorMapsToServiceError() async throws {
        MockURLProtocol.reset()
        mockHTTPError(statusCode: 502, errorType: "api_error")
        let provider = makeProvider()

        do {
            _ = try await provider.generateCompletion(userContent: "test", systemPrompt: "test", mode: nil)
            Issue.record("Expected error")
        } catch let error as AIProviderError {
            guard case .serviceError = error else {
                Issue.record("Expected .serviceError but got \(error)")
                return
            }
        }
    }

    @Test func configErrorMapsToServiceError() async throws {
        MockURLProtocol.reset()
        mockHTTPError(statusCode: 502, errorType: "config_error")
        let provider = makeProvider()

        do {
            _ = try await provider.generateCompletion(userContent: "test", systemPrompt: "test", mode: nil)
            Issue.record("Expected error")
        } catch let error as AIProviderError {
            guard case .serviceError = error else {
                Issue.record("Expected .serviceError but got \(error)")
                return
            }
        }
    }

    @Test func emptyResponseErrorTypeMapsToEmptyResponse() async throws {
        MockURLProtocol.reset()
        mockHTTPError(statusCode: 502, errorType: "empty_response")
        let provider = makeProvider()

        do {
            _ = try await provider.generateCompletion(userContent: "test", systemPrompt: "test", mode: nil)
            Issue.record("Expected error")
        } catch let error as AIProviderError {
            guard case .emptyResponse = error else {
                Issue.record("Expected .emptyResponse but got \(error)")
                return
            }
        }
    }

    // MARK: - Backwards Compatibility

    @Test func missingErrorTypeFallsBackToServiceUnavailable() async throws {
        MockURLProtocol.reset()
        mockLegacyHTTPError(statusCode: 502)
        let provider = makeProvider()

        do {
            _ = try await provider.generateCompletion(userContent: "test", systemPrompt: "test", mode: nil)
            Issue.record("Expected error")
        } catch let error as AIProviderError {
            guard case .serviceUnavailable = error else {
                Issue.record("Expected .serviceUnavailable but got \(error)")
                return
            }
        }
    }

    @Test func unknownErrorTypeFallsBackToServiceUnavailable() async throws {
        MockURLProtocol.reset()
        mockHTTPError(statusCode: 502, errorType: "some_future_type")
        let provider = makeProvider()

        do {
            _ = try await provider.generateCompletion(userContent: "test", systemPrompt: "test", mode: nil)
            Issue.record("Expected error")
        } catch let error as AIProviderError {
            guard case .serviceUnavailable = error else {
                Issue.record("Expected .serviceUnavailable but got \(error)")
                return
            }
        }
    }

    // MARK: - Decode Auth Regression (HTTP status, not error_type)

    @Test func http401MapsToSessionExpired() async throws {
        MockURLProtocol.reset()
        mockHTTPStatus(401)
        let provider = makeProvider()

        do {
            _ = try await provider.generateCompletion(userContent: "test", systemPrompt: "test", mode: nil)
            Issue.record("Expected error")
        } catch let error as AIProviderError {
            guard case .sessionExpired = error else {
                Issue.record("Expected .sessionExpired but got \(error)")
                return
            }
        }
    }

    @Test func http403MapsToAccountDisabled() async throws {
        MockURLProtocol.reset()
        mockHTTPStatus(403)
        let provider = makeProvider()

        do {
            _ = try await provider.generateCompletion(userContent: "test", systemPrompt: "test", mode: nil)
            Issue.record("Expected error")
        } catch let error as AIProviderError {
            guard case .accountDisabled = error else {
                Issue.record("Expected .accountDisabled but got \(error)")
                return
            }
        }
    }

    @Test func http429MapsToRateLimited() async throws {
        MockURLProtocol.reset()
        mockHTTPStatus(429)
        let provider = makeProvider()

        do {
            _ = try await provider.generateCompletion(userContent: "test", systemPrompt: "test", mode: nil)
            Issue.record("Expected error")
        } catch let error as AIProviderError {
            guard case .rateLimited = error else {
                Issue.record("Expected .rateLimited but got \(error)")
                return
            }
        }
    }

    @Test func http422MapsToServiceError() async throws {
        MockURLProtocol.reset()
        mockHTTPStatus(422)
        let provider = makeProvider()

        do {
            _ = try await provider.generateCompletion(userContent: "test", systemPrompt: "test", mode: nil)
            Issue.record("Expected error")
        } catch let error as AIProviderError {
            guard case .serviceError = error else {
                Issue.record("Expected .serviceError but got \(error)")
                return
            }
        }
    }

    // MARK: - SSE Error No Longer Maps to invalidResponse

    /// Proves that the no-credits scenario (api_error from provider billing)
    /// no longer produces invalidResponse.
    @Test func providerBillingErrorDoesNotProduceInvalidResponse() async throws {
        MockURLProtocol.reset()
        mockHTTPError(statusCode: 502, errorType: "api_error")
        let provider = makeProvider()

        do {
            _ = try await provider.generateCompletion(userContent: "test", systemPrompt: "test", mode: nil)
            Issue.record("Expected error")
        } catch let error as AIProviderError {
            if case .invalidResponse = error {
                Issue.record("api_error must NOT map to .invalidResponse — got \(error)")
            }
            guard case .serviceError = error else {
                Issue.record("Expected .serviceError but got \(error)")
                return
            }
        }
    }

    // MARK: - Error Message Tests

    @Test func serviceErrorMessage() {
        let error = AIProviderError.serviceError
        #expect(error.errorDescription == "Decode's AI service could not complete this request. Please try again later.")
    }

    @Test func serviceUnavailableMessage() {
        let error = AIProviderError.serviceUnavailable
        #expect(error.errorDescription == "Decode's AI service is temporarily unavailable. Please try again in a moment.")
    }

    @Test func rateLimitedWithSecondsMessage() {
        let error = AIProviderError.rateLimited(retryAfter: 30)
        #expect(error.errorDescription == "Decode is handling a lot of requests. Try again in 30 seconds.")
    }

    @Test func rateLimitedWithoutSecondsMessage() {
        let error = AIProviderError.rateLimited(retryAfter: nil)
        #expect(error.errorDescription == "Decode is handling a lot of requests right now. Please try again in a moment.")
    }

    @Test func sessionExpiredMessageUnchanged() {
        let error = AIProviderError.sessionExpired
        #expect(error.errorDescription == "Your Decode session is no longer valid. Please restart Decode.")
    }

    @Test func accountDisabledMessageUnchanged() {
        let error = AIProviderError.accountDisabled
        #expect(error.errorDescription == "Your Decode account has been disabled.")
    }

    @Test func invalidResponseMessageUnchanged() {
        let error = AIProviderError.invalidResponse(detail: "some detail")
        #expect(error.errorDescription == "Received an unexpected response. Please try again.")
    }

    @Test func timeoutMessageUnchanged() {
        let error = AIProviderError.timeout
        #expect(error.errorDescription == "Request timed out. Please try again.")
    }

    @Test func networkErrorMessageUnchanged() {
        let error = AIProviderError.networkError(underlying: URLError(.notConnectedToInternet))
        #expect(error.errorDescription == "Unable to connect to Decode. Check your internet connection.")
    }

    @Test func emptyResponseMessageUnchanged() {
        let error = AIProviderError.emptyResponse
        #expect(error.errorDescription == "No response received. Please try again.")
    }
}
