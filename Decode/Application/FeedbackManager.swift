import Foundation
import SwiftUI

/// Manages feedback scheduling and submission via the analytics event pipeline.
///
/// Explanation feedback is shown every 5 completed explanations.
/// Optimisation feedback is shown after every completed optimisation.
/// Feedback is submitted as an analytics event — no dedicated backend endpoint.
@Observable
@MainActor
final class FeedbackManager {

    /// Number of explanations completed since last feedback prompt.
    @ObservationIgnored
    @AppStorage("feedbackExplanationCount") private var explanationCount: Int = 0

    /// Whether feedback UI should currently be displayed.
    private(set) var showingFeedback = false

    /// The feature being rated ("explain" or "optimise").
    private(set) var feedbackFeature: String = ""

    /// Metadata captured at the time feedback is triggered.
    private(set) var feedbackMetadata: [String: Any] = [:]

    /// Whether the user has already responded to the current feedback prompt.
    private(set) var feedbackSubmitted = false

    // MARK: - Scheduling

    /// Call after each completed explanation.
    func recordExplanation(metadata: [String: Any]) {
        explanationCount += 1
        if explanationCount >= 5 {
            explanationCount = 0
            feedbackFeature = "explain"
            feedbackMetadata = metadata
            feedbackSubmitted = false
            showingFeedback = true
        }
    }

    /// Call after each completed optimisation. Always shows feedback.
    func recordOptimisation(metadata: [String: Any]) {
        feedbackFeature = "optimise"
        feedbackMetadata = metadata
        feedbackSubmitted = false
        showingFeedback = true
    }

    // MARK: - Submission

    /// Submit feedback as an analytics event.
    func submitFeedback(liked: Bool) {
        var meta = feedbackMetadata
        meta["feature"] = feedbackFeature
        meta["liked"] = liked

        AnalyticsEventService.send(
            eventType: "feedback",
            mode: feedbackMetadata["mode"] as? String,
            metadata: meta
        )

        feedbackSubmitted = true

        // Auto-dismiss after a short delay.
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            showingFeedback = false
        }
    }

    /// Dismiss feedback without responding.
    func dismissFeedback() {
        showingFeedback = false
    }

    /// Reset state (called when HUD is dismissed).
    func reset() {
        showingFeedback = false
        feedbackSubmitted = false
        feedbackFeature = ""
        feedbackMetadata = [:]
    }
}
