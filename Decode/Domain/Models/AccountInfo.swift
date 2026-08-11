// AccountInfo.swift — Decode Domain
//
// Lightweight model representing the authenticated user's account metadata
// as returned by the backend /api/auth/validate endpoint.
//
// This is a read-only snapshot of server-side account data — not a mutable
// profile. Updates come exclusively from re-validation with the backend.

import Foundation

/// Account metadata for the authenticated user.
///
/// Populated from the expanded `/api/auth/validate` response.
/// All fields except `userId` and `status` are optional because the
/// backend may not have them (e.g., name was never set by admin).
struct AccountInfo: Codable, Sendable, Equatable {

    /// Server-assigned user identifier.
    let userId: String

    /// Account status: "active", "disabled", etc.
    let status: String

    /// Display name set by admin, if available.
    let name: String?

    /// Email address associated with the account.
    let email: String?

    /// When the invite code was activated, if available.
    let activatedAt: Date?
}
