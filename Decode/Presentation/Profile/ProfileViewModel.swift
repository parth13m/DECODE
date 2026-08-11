// ProfileViewModel.swift — Decode Presentation
//
// View model for the Profile page. Coordinates account metadata
// from AuthService and the derived UserProfile from Profile Intelligence.
//
// This is a pure consumer — it does not modify authentication state,
// profile observations, or derivation logic.

import Foundation

/// View model for the Profile page.
///
/// Loads account information from ``AuthService`` and the derived
/// ``UserProfile`` from ``ProfileIntelligenceService``. Both are
/// read-only from this view model's perspective.
@Observable
@MainActor
final class ProfileViewModel {

    // MARK: - State

    /// Account metadata from the backend. `nil` before first load.
    private(set) var accountInfo: AccountInfo?

    /// Derived user profile from Profile Intelligence.
    private(set) var profile: UserProfile = .empty

    /// Whether the profile is currently loading.
    private(set) var isLoadingProfile = true

    // MARK: - Dependencies

    private let authService: AuthService
    private let profileService: ProfileIntelligenceService?

    // MARK: - Init

    init(authService: AuthService, profileService: ProfileIntelligenceService?) {
        self.authService = authService
        self.profileService = profileService
    }

    // MARK: - Loading

    /// Load all Profile page data.
    func load() async {
        accountInfo = authService.accountInfo
        await loadProfile()
    }

    /// Reload the profile from Profile Intelligence.
    func loadProfile() async {
        isLoadingProfile = true
        if let service = profileService {
            profile = await service.currentProfile()
        }
        isLoadingProfile = false
    }

    // MARK: - Account Helpers

    /// The user's display name, falling back to email or user ID.
    var displayName: String {
        if let name = accountInfo?.name, !name.isEmpty {
            return name
        }
        if let email = accountInfo?.email, !email.isEmpty {
            return email
        }
        return userId ?? "Decode User"
    }

    /// The user ID from UserDefaults (always available when authenticated).
    var userId: String? {
        UserDefaults.standard.string(forKey: "decodeAuthenticatedUserID")
    }

    /// App version from the main bundle.
    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    /// App build number from the main bundle.
    var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    // MARK: - Actions

    /// Sign out — delegates to AuthService.
    func signOut() {
        authService.signOut()
    }
}
