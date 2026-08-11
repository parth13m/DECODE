import Foundation
import os.log

private let authLog = Logger(subsystem: "com.decode.app", category: "auth-diag")

/// Manages authentication state for the Decode platform.
///
/// Responsibilities:
/// - Activate invite codes via the backend
/// - Store/retrieve access tokens in the macOS Keychain
/// - Validate tokens on launch
/// - Track authentication state for the view layer
///
/// Follows the two-phase startup pattern: construct in `AppDependencies.init()`,
/// call ``checkAuthOnLaunch()`` during deferred startup.
@Observable
@MainActor
final class AuthService {

    // MARK: - State

    /// Current authentication state. Observed by ContentView for the centralized gate.
    private(set) var state: AuthState = .authenticating

    /// Account metadata populated from the validate response.
    /// Available only after successful authentication.
    private(set) var accountInfo: AccountInfo?

    // MARK: - Dependencies

    private let keychain: KeychainService
    private let session: URLSession

    // MARK: - Constants

    private static let tokenKeychainAccount = "decode-access-token"
    private static let userIdKey = "decodeAuthenticatedUserID"

    // MARK: - Init

    init(keychain: KeychainService = KeychainService(), session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    // MARK: - Launch Flow

    /// Check authentication state on app launch.
    ///
    /// 1. Check Keychain for stored token
    /// 2. If token exists, validate with backend
    /// 3. Set state accordingly
    func checkAuthOnLaunch() async {
        authLog.notice("[DIAG] checkAuthOnLaunch — START")

        authLog.notice("[DIAG] checkAuthOnLaunch — calling storedToken (Keychain)")
        let token = storedToken
        authLog.notice("[DIAG] checkAuthOnLaunch — storedToken returned, hasToken=\(token != nil)")

        guard let token, !token.isEmpty else {
            authLog.notice("[DIAG] checkAuthOnLaunch — no token, setting .needsInvite")
            state = .needsInvite
            return
        }

        authLog.notice("[DIAG] checkAuthOnLaunch — token found, calling validateToken")
        await validateToken(token)
        authLog.notice("[DIAG] checkAuthOnLaunch — END, state=\(String(describing: self.state))")
    }

    // MARK: - Invite Code Activation

    /// Activate an invite code and store the returned access token.
    ///
    /// This intentionally does NOT set ``AuthState/authenticating`` during the
    /// network call. Both ``InviteCodeView`` and ``OnboardingView`` provide their
    /// own local loading UI (`isActivating`). Setting the global `.authenticating`
    /// state would swap ContentView to the "Verifying account…" screen, destroying
    /// the caller's view — and if `performRequest` throws (DNS/network failure),
    /// the state was never restored, trapping the user on a dead-end screen with
    /// no retry button.
    ///
    /// - Parameters:
    ///   - inviteCode: The invite code entered by the user (e.g., "DECODE-ABCD-EFGH")
    ///   - email: Optional email address
    /// - Throws: ``AuthError`` on failure
    func activateInviteCode(_ inviteCode: String, email: String? = nil) async throws {
        authLog.notice("[DIAG] activateInviteCode — START, code=\(inviteCode.prefix(5))...")

        let url = DecodeConfig.backendBaseURL.appendingPathComponent("api/auth/activate")
        authLog.notice("[DIAG] activateInviteCode — URL=\(url.absoluteString)")

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = ["invite_code": inviteCode]
        if let email, !email.isEmpty {
            body["email"] = email
        }
        request.httpBody = try JSONEncoder().encode(body)

        authLog.notice("[DIAG] activateInviteCode — sending request...")
        let (data, response) = try await performRequest(request)
        authLog.notice("[DIAG] activateInviteCode — response received")

        guard let httpResponse = response as? HTTPURLResponse else {
            authLog.error("[DIAG] activateInviteCode — non-HTTP response")
            state = .error("Invalid server response")
            throw AuthError.invalidResponse
        }

        authLog.notice("[DIAG] activateInviteCode — HTTP \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            let result = try JSONDecoder().decode(ActivateResponse.self, from: data)
            authLog.notice("[DIAG] activateInviteCode — decoded OK, storing token")
            try storeToken(result.accessToken)
            authLog.notice("[DIAG] activateInviteCode — token stored, setting .authenticated")
            UserDefaults.standard.set(result.userId, forKey: Self.userIdKey)
            state = .authenticated

            #if DEBUG
            print("[DEBUG Auth] Invite activated — userId=\(result.userId)")
            #endif

        case 404:
            authLog.notice("[DIAG] activateInviteCode — 404 invalid code")
            state = .needsInvite
            throw AuthError.invalidInviteCode

        case 409:
            authLog.notice("[DIAG] activateInviteCode — 409 already used")
            state = .needsInvite
            throw AuthError.inviteAlreadyUsed

        default:
            let detail = extractErrorDetail(from: data)
            authLog.error("[DIAG] activateInviteCode — unexpected \(httpResponse.statusCode): \(detail)")
            state = .error(detail)
            throw AuthError.serverError(httpResponse.statusCode, detail)
        }
    }

    // MARK: - Token Validation

    /// Validate the stored token against the backend.
    private func validateToken(_ token: String) async {
        let url = DecodeConfig.backendBaseURL.appendingPathComponent("api/auth/validate")
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await performRequest(request)

            guard let httpResponse = response as? HTTPURLResponse else {
                state = .offline
                return
            }

            switch httpResponse.statusCode {
            case 200:
                if let result = try? JSONDecoder().decode(ValidateResponse.self, from: data) {
                    UserDefaults.standard.set(result.userId, forKey: Self.userIdKey)
                    accountInfo = AccountInfo(
                        userId: result.userId,
                        status: result.status,
                        name: result.name,
                        email: result.email,
                        activatedAt: Self.parseISO8601(result.activatedAt)
                    )
                }
                state = .authenticated
                #if DEBUG
                print("[DEBUG Auth] Token validated successfully")
                #endif

            case 401:
                // Token invalid — clear and require re-authentication.
                clearToken()
                state = .needsInvite
                #if DEBUG
                print("[DEBUG Auth] Token invalid — cleared")
                #endif

            case 403:
                state = .disabled
                #if DEBUG
                print("[DEBUG Auth] Account disabled")
                #endif

            default:
                state = .offline
            }
        } catch {
            // Network failure — don't delete token, allow offline state.
            state = .offline
            #if DEBUG
            print("[DEBUG Auth] Validation failed (network): \(error.localizedDescription)")
            #endif
        }
    }

    /// Retry validation when in offline state.
    func retryValidation() async {
        guard let token = storedToken, !token.isEmpty else {
            state = .needsInvite
            return
        }
        state = .authenticating
        await validateToken(token)
    }

    // MARK: - Token Management

    /// The currently stored access token, or `nil` if none exists.
    var storedToken: String? {
        authLog.notice("[DIAG] storedToken — calling Keychain.retrieve")
        do {
            let value = try keychain.retrieve(forAccount: Self.tokenKeychainAccount)
            authLog.notice("[DIAG] storedToken — Keychain returned, hasValue=\(value != nil)")
            return value
        } catch {
            authLog.error("[DIAG] storedToken — Keychain threw: \(error.localizedDescription)")
            return nil
        }
    }

    /// Whether a token is stored in the Keychain.
    var hasStoredToken: Bool {
        storedToken != nil
    }

    /// Store a token in the Keychain.
    private func storeToken(_ token: String) throws {
        try keychain.store(token, forAccount: Self.tokenKeychainAccount)
    }

    /// Clear the stored token from Keychain and UserDefaults.
    private func clearToken() {
        try? keychain.delete(forAccount: Self.tokenKeychainAccount)
        UserDefaults.standard.removeObject(forKey: Self.userIdKey)
    }

    /// Sign out — clear token and reset to invite flow.
    func signOut() {
        clearToken()
        accountInfo = nil
        state = .needsInvite
    }

    // MARK: - Networking Helpers

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    /// Parse an ISO 8601 date string from the backend.
    private static func parseISO8601(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private func extractErrorDetail(from data: Data) -> String {
        if let json = try? JSONDecoder().decode([String: String].self, from: data),
           let detail = json["detail"] {
            return detail
        }
        return "An unexpected error occurred"
    }
}

// MARK: - Response Models

private struct ActivateResponse: Decodable {
    let accessToken: String
    let userId: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case userId = "user_id"
        case status
    }
}

private struct ValidateResponse: Decodable {
    let userId: String
    let status: String
    let name: String?
    let email: String?
    let activatedAt: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case status
        case name
        case email
        case activatedAt = "activated_at"
    }
}

// MARK: - Auth Errors

/// Errors from authentication operations.
enum AuthError: Error, LocalizedError {
    case invalidInviteCode
    case inviteAlreadyUsed
    case invalidResponse
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidInviteCode:
            "Invalid invite code. Please check and try again."
        case .inviteAlreadyUsed:
            "This invite code has already been used."
        case .invalidResponse:
            "Invalid response from the server."
        case .serverError(_, let detail):
            detail
        }
    }
}
