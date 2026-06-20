import Foundation

/// Authentication states for the Decode platform.
///
/// Used by ``AuthService`` and observed by the view layer to gate
/// access to all Decode functionality behind authentication.
enum AuthState: Equatable {
    /// No token stored — user must enter an invite code.
    case needsInvite
    /// Activation or validation in progress.
    case authenticating
    /// Token validated — full access granted.
    case authenticated
    /// Backend returned 403 — account disabled by admin.
    case disabled
    /// Token exists but validation failed due to network error.
    case offline
    /// An unexpected error occurred during authentication.
    case error(String)
}

// MARK: - Backend Configuration

/// Centralized configuration for the Decode backend.
///
/// Uses a compile-time debug/release switch with an optional UserDefaults
/// override for development flexibility.
enum DecodeConfig {

    private static let baseURLOverrideKey = "decodeBackendBaseURL"

    /// The base URL for the Decode backend API.
    ///
    /// In DEBUG builds, defaults to `http://localhost:8000`.
    /// Can be overridden via UserDefaults key `decodeBackendBaseURL`.
    static var backendBaseURL: URL {
        if let override = UserDefaults.standard.string(forKey: baseURLOverrideKey),
           !override.isEmpty,
           let url = URL(string: override) {
            return url
        }
        #if DEBUG
        return URL(string: "http://localhost:8000")!
        #else
        return URL(string: "https://decode-production-2884.up.railway.app")!
        #endif
    }
}
