import Foundation

/// Errors that can occur during AI provider operations.
enum AIProviderError: Error, LocalizedError, Sendable {

    /// The user is not authenticated (no token stored).
    case notAuthenticated

    /// The session has expired or token was revoked (HTTP 401).
    case sessionExpired

    /// The user's account has been disabled (HTTP 403).
    case accountDisabled

    /// The Decode service is temporarily unavailable (HTTP 502 / 5xx).
    case serviceUnavailable

    /// Rate limited by the provider (HTTP 429).
    /// Contains the `Retry-After` duration if the header was present.
    case rateLimited(retryAfter: TimeInterval?)

    /// The request timed out.
    case timeout

    /// A network-level failure (no connectivity, DNS failure, etc.).
    case networkError(underlying: Error)

    /// All retry attempts exhausted.
    case retriesExhausted(lastError: Error)

    /// The response could not be parsed.
    case invalidResponse(detail: String)

    /// The streaming connection was interrupted before completing.
    case streamInterrupted

    /// The stream completed but produced no content.
    case emptyResponse

    // MARK: - Legacy cases (kept for compilation of unused providers)

    /// Legacy: API key is missing. Mapped to `notAuthenticated` in gateway flow.
    case apiKeyMissing

    /// Legacy: Invalid API key. Mapped to `sessionExpired` in gateway flow.
    case invalidAPIKey

    /// Legacy: Provider-specific error.
    case providerError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "You are not signed in. Please restart Decode and enter your invite code."
        case .sessionExpired:
            "Your Decode session is no longer valid. Please restart Decode."
        case .accountDisabled:
            "Your Decode account has been disabled."
        case .serviceUnavailable:
            "Decode service is temporarily unavailable. Please try again."
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                "Rate limited. Try again in \(Int(seconds)) seconds."
            } else {
                "Rate limited. Try again shortly."
            }
        case .timeout:
            "Request timed out. Please try again."
        case .networkError:
            "Unable to connect to Decode. Check your internet connection."
        case .retriesExhausted:
            "Request failed after multiple retries. Please try again."
        case .invalidResponse:
            "Received an unexpected response. Please try again."
        case .streamInterrupted:
            "The response was interrupted. Check your connection and try again."
        case .emptyResponse:
            "No response received. Please try again."
        case .apiKeyMissing:
            "You are not signed in. Please restart Decode and enter your invite code."
        case .invalidAPIKey:
            "Your Decode session is no longer valid. Please restart Decode."
        case .providerError(_, let message):
            message
        }
    }
}
