// ProfileSyncService.swift — Decode Infrastructure
//
// Fire-and-forget synchronization of the derived UserProfile to the
// Decode backend. The backend stores the profile as a JSONB snapshot
// for admin inspection.
//
// Follows the AnalyticsEventService pattern: static enum, detached task,
// short timeout, silent failure. Profile sync must never block the
// main explanation path.

import Foundation
import os.log

private let syncLog = Logger(subsystem: "com.decode.app", category: "profile-sync")

/// Sends the derived UserProfile to the backend as a fire-and-forget snapshot.
///
/// The backend stores the profile as an opaque JSONB blob on the `users` table.
/// Admin dashboards can inspect it. The macOS Profile Intelligence system
/// remains the authoritative source of truth — the backend snapshot is read-only.
enum ProfileSyncService {

    /// Send the derived profile to `POST /api/gateway/profile`.
    ///
    /// Fire-and-forget: spawns a detached task so the caller doesn't wait.
    /// Failures are silently logged — profile sync should never block UX.
    static func sync(profile: UserProfile) {
        // Encode on the calling thread so only Sendable Data crosses the boundary.
        guard let profileData = Self.encodeProfilePayload(profile) else {
            return
        }

        Task.detached(priority: .utility) {
            await _send(profileData: profileData)
        }
    }

    // MARK: - Payload Encoding

    /// Encode the profile into the JSON payload expected by the backend.
    ///
    /// The payload shape:
    /// ```json
    /// {
    ///   "profile_version": 1,
    ///   "total_observation_count": 42,
    ///   "profile_data": { ... full UserProfile as JSON ... }
    /// }
    /// ```
    private static func encodeProfilePayload(_ profile: UserProfile) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let profileJSON = try? encoder.encode(profile),
              let profileDict = try? JSONSerialization.jsonObject(with: profileJSON) as? [String: Any]
        else {
            #if DEBUG
            syncLog.debug("profile sync: failed to encode UserProfile")
            #endif
            return nil
        }

        let payload: [String: Any] = [
            "profile_version": profile.profileVersion,
            "total_observation_count": profile.totalObservationCount,
            "profile_data": profileDict,
        ]

        return try? JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - Network

    private static func _send(profileData: Data) async {
        let keychain = KeychainService()
        guard let token = try? keychain.retrieve(forAccount: "decode-access-token"),
              !token.isEmpty
        else {
            #if DEBUG
            syncLog.debug("profile sync skipped: no auth token")
            #endif
            return
        }

        let url = DecodeConfig.backendBaseURL
            .appendingPathComponent("api/gateway/profile")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = profileData
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 204 {
                #if DEBUG
                syncLog.debug("profile sync returned status=\(status, privacy: .public)")
                #endif
            }
        } catch {
            #if DEBUG
            syncLog.debug("profile sync failed: \(error.localizedDescription, privacy: .public)")
            #endif
        }
    }
}
