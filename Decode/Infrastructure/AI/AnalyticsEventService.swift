import Foundation
import os.log

private let analyticsLog = Logger(subsystem: "com.decode.analytics", category: "events")

/// Lightweight fire-and-forget client for reporting analytics events to the
/// Decode backend. Events are best-effort — failures are logged but never
/// surface to the user.
enum AnalyticsEventService {

    /// Report a client-side analytics event to `POST /api/gateway/analytics/event`.
    ///
    /// Fire-and-forget: spawns a detached task so the caller doesn't wait.
    /// Failures are silently logged — analytics should never block UX.
    static func send(
        eventType: String,
        mode: String?,
        metadata: [String: Any]? = nil
    ) {
        // Serialize metadata to JSON Data on the calling thread so only
        // Sendable values cross the concurrency boundary.
        let metadataJSON: Data? = if let metadata {
            try? JSONSerialization.data(withJSONObject: metadata)
        } else {
            nil
        }
        let eventType = eventType
        let mode = mode
        Task.detached(priority: .utility) {
            await _send(eventType: eventType, mode: mode, metadataJSON: metadataJSON)
        }
    }

    private static func _send(
        eventType: String,
        mode: String?,
        metadataJSON: Data?
    ) async {
        let keychain = KeychainService()
        guard let token = try? keychain.retrieve(forAccount: "decode-access-token"),
              !token.isEmpty
        else {
            #if DEBUG
            analyticsLog.debug("analytics event skipped: no auth token")
            #endif
            return
        }

        let url = DecodeConfig.backendBaseURL
            .appendingPathComponent("api/gateway/analytics/event")

        // Build the JSON body, embedding pre-serialized metadata if present.
        var bodyDict: [String: Any] = ["event_type": eventType]
        if let mode { bodyDict["mode"] = mode }
        if let metadataJSON,
           let metadataObj = try? JSONSerialization.jsonObject(with: metadataJSON) {
            bodyDict["metadata"] = metadataObj
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 204 {
                #if DEBUG
                analyticsLog.debug("analytics event \(eventType, privacy: .public) returned status=\(status, privacy: .public)")
                #endif
            }
        } catch {
            #if DEBUG
            analyticsLog.debug("analytics event \(eventType, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            #endif
        }
    }
}
