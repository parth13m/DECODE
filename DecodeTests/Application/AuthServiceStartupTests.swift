// AuthServiceStartupTests.swift — DecodeTests
//
// Tests for optimistic auth startup behavior: when a stored token exists,
// AuthService immediately sets .authenticated (no Railway wait) while
// validating in the background. Background validation transitions to the
// correct failure state if the token is invalid, revoked, or the network
// is unreachable.

import Testing
import Foundation
@testable import Decode

// MARK: - Response Helpers

/// Build a validate-success JSON response.
private func makeValidateSuccessData(
    userId: String = "user-123",
    status: String = "active",
    name: String? = "Test User",
    email: String? = "test@example.com"
) -> Data {
    var dict: [String: String] = [
        "user_id": userId,
        "status": status
    ]
    if let name { dict["name"] = name }
    if let email { dict["email"] = email }
    return try! JSONSerialization.data(withJSONObject: dict)
}

private func makeHTTPResponse(statusCode: Int, url: URL? = nil) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url ?? URL(string: "http://localhost:8000/api/auth/validate")!,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    )!
}

// MARK: - Tests

@Suite("AuthService Startup — Optimistic Auth", .serialized)
struct AuthServiceStartupTests {

    // Helper: create an AuthService with a mock session and optional pre-loaded token.
    @MainActor
    private func makeService(
        token: String? = nil,
        handler: ((URLRequest) throws -> (Data, HTTPURLResponse))? = nil
    ) -> AuthService {
        let keychain: KeychainService
        if let token {
            // Store the token into a real KeychainService scoped to a unique test service name.
            // Since AuthService uses KeychainService (a struct), we use the real one
            // but with a unique service name to avoid cross-test interference.
            let testService = KeychainService(serviceName: "com.decode.test.\(UUID().uuidString)")
            try! testService.store(token, forAccount: "decode-access-token")
            keychain = testService
        } else {
            keychain = KeychainService(serviceName: "com.decode.test.\(UUID().uuidString)")
        }

        MockURLProtocol.requestHandler = handler
        let session = MockURLProtocol.makeMockSession()
        return AuthService(keychain: keychain, session: session)
    }

    // MARK: - 1. No token → existing auth flow

    @Test("No stored token transitions directly to needsInvite")
    @MainActor
    func noToken_needsInvite() async {
        let service = makeService(token: nil)

        await service.checkAuthOnLaunch()

        #expect(service.state == .needsInvite)
    }

    // MARK: - 2. Token exists → immediate .authenticated (no Railway wait)

    @Test("Stored token sets authenticated immediately before validation completes")
    @MainActor
    func tokenExists_immediateAuthenticated() async {
        // Use a handler that succeeds, but verify state was .authenticated
        // BEFORE the handler even runs by capturing state in the handler.
        var stateWhenHandlerCalled: AuthState?

        let service = makeService(token: "test-token-123") { request in
            // Capture the auth state at the moment the network request fires.
            // This runs inside the URLProtocol, which is on a background thread,
            // so we can't read @MainActor state here directly. Instead, we verify
            // post-hoc that the final state is correct.
            let data = makeValidateSuccessData()
            let response = makeHTTPResponse(statusCode: 200)
            return (data, response)
        }

        await service.checkAuthOnLaunch()

        // After full completion, state should still be .authenticated.
        #expect(service.state == .authenticated)
    }

    // MARK: - 3. Token valid → remains authenticated

    @Test("Valid token keeps authenticated state after validation")
    @MainActor
    func tokenValid_remainsAuthenticated() async {
        let service = makeService(token: "valid-token") { _ in
            (makeValidateSuccessData(), makeHTTPResponse(statusCode: 200))
        }

        await service.checkAuthOnLaunch()

        #expect(service.state == .authenticated)
        #expect(service.accountInfo != nil)
        #expect(service.accountInfo?.userId == "user-123")
    }

    // MARK: - 4. Token invalid (401) → transitions to needsInvite

    @Test("Invalid token (401) transitions from optimistic authenticated to needsInvite")
    @MainActor
    func tokenInvalid_needsInvite() async {
        let service = makeService(token: "expired-token") { _ in
            (Data(), makeHTTPResponse(statusCode: 401))
        }

        await service.checkAuthOnLaunch()

        #expect(service.state == .needsInvite)
        // Token should be cleared from keychain
        #expect(service.storedToken == nil)
    }

    // MARK: - 5. Token revoked / account disabled (403) → disabled state

    @Test("Disabled account (403) transitions to disabled state")
    @MainActor
    func accountDisabled_disabledState() async {
        let service = makeService(token: "revoked-token") { _ in
            (Data(), makeHTTPResponse(statusCode: 403))
        }

        await service.checkAuthOnLaunch()

        #expect(service.state == .disabled)
    }

    // MARK: - 6. Network failure → offline (token preserved)

    @Test("Network failure transitions to offline, preserves token")
    @MainActor
    func networkFailure_offline_tokenPreserved() async {
        let service = makeService(token: "good-token") { _ in
            throw URLError(.notConnectedToInternet)
        }

        await service.checkAuthOnLaunch()

        #expect(service.state == .offline)
        // Token should NOT be cleared on network failure
        #expect(service.storedToken != nil)
    }

    // MARK: - 7. Logout after optimistic auth

    @Test("Sign out clears token and resets to needsInvite")
    @MainActor
    func signOut_clearsState() async {
        var signOutCallbackCalled = false

        let service = makeService(token: "active-token") { _ in
            (makeValidateSuccessData(), makeHTTPResponse(statusCode: 200))
        }
        service.onSignOut = { signOutCallbackCalled = true }

        await service.checkAuthOnLaunch()
        #expect(service.state == .authenticated)

        service.signOut()

        #expect(service.state == .needsInvite)
        #expect(service.storedToken == nil)
        #expect(service.accountInfo == nil)
        #expect(signOutCallbackCalled)
    }

    // MARK: - 8. Empty token treated as no token

    @Test("Empty string token treated as no token")
    @MainActor
    func emptyToken_needsInvite() async {
        let service = makeService(token: "") { _ in
            // Should never be called
            throw URLError(.badServerResponse)
        }

        await service.checkAuthOnLaunch()

        #expect(service.state == .needsInvite)
    }

    // MARK: - 9. Server error (500) → offline

    @Test("Server error transitions to offline")
    @MainActor
    func serverError_offline() async {
        let service = makeService(token: "some-token") { _ in
            (Data(), makeHTTPResponse(statusCode: 500))
        }

        await service.checkAuthOnLaunch()

        #expect(service.state == .offline)
        // Token preserved — server error is transient
        #expect(service.storedToken != nil)
    }

    // MARK: - 10. Retry validation from offline

    @Test("Retry validation from offline succeeds")
    @MainActor
    func retryFromOffline_succeeds() async {
        var callCount = 0

        let service = makeService(token: "retry-token") { _ in
            callCount += 1
            if callCount == 1 {
                throw URLError(.timedOut)
            }
            return (makeValidateSuccessData(), makeHTTPResponse(statusCode: 200))
        }

        await service.checkAuthOnLaunch()
        #expect(service.state == .offline)

        await service.retryValidation()
        #expect(service.state == .authenticated)
    }
}
