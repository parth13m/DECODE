import Foundation

/// Tracks AI request usage with a rolling time-window quota.
///
/// Decode provides API keys and pays inference costs. This tracker enforces
/// a request limit within a rolling window to control cost exposure.
///
/// Timestamps are persisted to UserDefaults so the quota survives app restarts.
/// All access is `@MainActor`-isolated — no concurrent mutation.
@MainActor
final class AIUsageTracker {

    private static let storageKey = "ai_request_timestamps"

    /// In-memory copy of request timestamps within the current window.
    private var timestamps: [Date]

    init() {
        // Load persisted timestamps and prune stale entries.
        if let stored = UserDefaults.standard.array(forKey: Self.storageKey) as? [Double] {
            let cutoff = Date().addingTimeInterval(-AILimits.quotaWindowSeconds)
            timestamps = stored
                .map { Date(timeIntervalSince1970: $0) }
                .filter { $0 > cutoff }
        } else {
            timestamps = []
        }
    }

    /// Attempt to consume one request from the quota.
    ///
    /// Returns `true` if the request is allowed (under limit).
    /// Returns `false` if the quota is exhausted — caller should show an error.
    func tryConsumeRequest() -> Bool {
        prune()
        guard timestamps.count < AILimits.quotaRequestLimit else {
            return false
        }
        timestamps.append(Date())
        persist()
        return true
    }

    /// Number of requests remaining in the current window.
    var remainingRequests: Int {
        prune()
        return max(0, AILimits.quotaRequestLimit - timestamps.count)
    }

    /// The earliest time a quota slot will free up, or `nil` if quota is not exhausted.
    var nextAvailableDate: Date? {
        prune()
        guard timestamps.count >= AILimits.quotaRequestLimit else { return nil }
        // The oldest timestamp will expire first.
        guard let oldest = timestamps.min() else { return nil }
        return oldest.addingTimeInterval(AILimits.quotaWindowSeconds)
    }

    /// A user-facing message describing when the next slot opens.
    var quotaExhaustedMessage: String {
        if let next = nextAvailableDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "Request limit reached (\(AILimits.quotaRequestLimit) requests per 5-hour window). Next slot available at \(formatter.string(from: next))."
        }
        return "Request limit reached (\(AILimits.quotaRequestLimit) requests per 5-hour window). Please try again later."
    }

    // MARK: - Private

    /// Remove timestamps older than the rolling window.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-AILimits.quotaWindowSeconds)
        timestamps.removeAll { $0 <= cutoff }
    }

    /// Persist current timestamps to UserDefaults.
    private func persist() {
        let intervals = timestamps.map { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(intervals, forKey: Self.storageKey)
    }
}
