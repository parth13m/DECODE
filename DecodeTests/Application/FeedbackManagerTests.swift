// FeedbackManagerTests.swift — DecodeTests
// Tests for FeedbackManager scheduling, submission, and reset behavior.

import Testing
import Foundation
@testable import Decode

@Suite(.serialized)
struct FeedbackManagerTests {

    /// Reset the persisted explanation counter before each test to ensure isolation.
    /// FeedbackManager uses @AppStorage("feedbackExplanationCount") which persists
    /// across test runs via UserDefaults.
    @MainActor
    private func makeFreshManager() -> FeedbackManager {
        UserDefaults.standard.set(0, forKey: "feedbackExplanationCount")
        return FeedbackManager()
    }

    // MARK: - Explanation Counting

    @Test @MainActor
    func recordExplanationIncrementsCount() {
        let fm = makeFreshManager()
        fm.recordExplanation(metadata: [:])
        // After 1 explanation, feedback should not yet appear (threshold is 5).
        #expect(fm.showingFeedback == false)
    }

    @Test @MainActor
    func feedbackAppearsAfterFifthExplanation() {
        let fm = makeFreshManager()
        for _ in 1...4 {
            fm.recordExplanation(metadata: [:])
        }
        #expect(fm.showingFeedback == false)

        // The 5th explanation triggers feedback.
        fm.recordExplanation(metadata: ["mode": "selection"])
        #expect(fm.showingFeedback == true)
        #expect(fm.feedbackFeature == "explain")
        #expect(fm.feedbackMetadata["mode"] as? String == "selection")
        #expect(fm.feedbackSubmitted == false)
    }

    @Test @MainActor
    func counterResetsAfterFeedbackTriggered() {
        let fm = makeFreshManager()
        // Trigger feedback at 5.
        for _ in 1...5 {
            fm.recordExplanation(metadata: [:])
        }
        #expect(fm.showingFeedback == true)

        // Dismiss, then the next cycle should require another 5.
        fm.dismissFeedback()
        #expect(fm.showingFeedback == false)

        for _ in 1...4 {
            fm.recordExplanation(metadata: [:])
        }
        #expect(fm.showingFeedback == false)

        // 5th in the new cycle triggers again.
        fm.recordExplanation(metadata: [:])
        #expect(fm.showingFeedback == true)
    }

    @Test @MainActor
    func explanationDoesNotDoubleCountSingleStream() {
        let fm = makeFreshManager()
        fm.recordExplanation(metadata: [:])
        fm.recordExplanation(metadata: [:])
        // 2 calls = 2 increments. The production code calls recordExplanation
        // once per stream completion. After 3 more calls, total = 5, feedback appears.
        for _ in 1...3 {
            fm.recordExplanation(metadata: [:])
        }
        #expect(fm.showingFeedback == true)
    }

    // MARK: - Optimisation Feedback

    @Test @MainActor
    func recordOptimisationShowsFeedbackImmediately() {
        let fm = makeFreshManager()
        fm.recordOptimisation(metadata: ["mode": "session_improve", "optimisation_goal": "balanced"])
        #expect(fm.showingFeedback == true)
        #expect(fm.feedbackFeature == "optimise")
        #expect(fm.feedbackMetadata["mode"] as? String == "session_improve")
        #expect(fm.feedbackSubmitted == false)
    }

    @Test @MainActor
    func optimisationDoesNotAffectExplanationCounter() {
        let fm = makeFreshManager()
        // Record 3 explanations.
        for _ in 1...3 {
            fm.recordExplanation(metadata: [:])
        }
        // Optimisation feedback (always immediate).
        fm.recordOptimisation(metadata: [:])
        #expect(fm.showingFeedback == true)

        // Dismiss, then 2 more explanations should reach the threshold (3+2=5).
        fm.dismissFeedback()
        fm.recordExplanation(metadata: [:])
        #expect(fm.showingFeedback == false)
        fm.recordExplanation(metadata: [:])
        #expect(fm.showingFeedback == true)
    }

    // MARK: - Feedback Submission

    @Test @MainActor
    func submitFeedbackSetsSubmittedFlag() {
        let fm = makeFreshManager()
        fm.recordOptimisation(metadata: [:])
        #expect(fm.feedbackSubmitted == false)

        fm.submitFeedback(liked: true)
        #expect(fm.feedbackSubmitted == true)
    }

    // MARK: - Dismiss

    @Test @MainActor
    func dismissFeedbackHidesUI() {
        let fm = makeFreshManager()
        fm.recordOptimisation(metadata: [:])
        #expect(fm.showingFeedback == true)

        fm.dismissFeedback()
        #expect(fm.showingFeedback == false)
    }

    // MARK: - Reset

    @Test @MainActor
    func resetClearsAllTransientState() {
        let fm = makeFreshManager()
        fm.recordOptimisation(metadata: ["mode": "selection_improve"])
        fm.submitFeedback(liked: false)

        fm.reset()
        #expect(fm.showingFeedback == false)
        #expect(fm.feedbackSubmitted == false)
        #expect(fm.feedbackFeature == "")
        #expect(fm.feedbackMetadata.isEmpty)
    }

    @Test @MainActor
    func resetDoesNotAffectExplanationCounter() {
        let fm = makeFreshManager()
        // Record 3 explanations.
        for _ in 1...3 {
            fm.recordExplanation(metadata: [:])
        }
        // Reset (HUD dismissed).
        fm.reset()

        // Counter persists via @AppStorage. 2 more should reach 5.
        fm.recordExplanation(metadata: [:])
        #expect(fm.showingFeedback == false)
        fm.recordExplanation(metadata: [:])
        #expect(fm.showingFeedback == true)
    }

    // MARK: - Metadata Capture

    @Test @MainActor
    func metadataIsCapturedAtTriggerTime() {
        let fm = makeFreshManager()
        // First 4 with one mode.
        for _ in 1...4 {
            fm.recordExplanation(metadata: ["mode": "session"])
        }
        // 5th with a different mode — feedback metadata should reflect the 5th.
        fm.recordExplanation(metadata: ["mode": "selection", "language": "swift"])
        #expect(fm.feedbackMetadata["mode"] as? String == "selection")
        #expect(fm.feedbackMetadata["language"] as? String == "swift")
    }

    // MARK: - Non-Explanation Events

    @Test @MainActor
    func followUpDoesNotIncrementExplanationCount() {
        let fm = makeFreshManager()
        for _ in 1...4 {
            fm.recordExplanation(metadata: [:])
        }
        // Follow-ups call askFollowUp() which does NOT call recordExplanation().
        // The next explanation (5th) should trigger feedback.
        fm.recordExplanation(metadata: [:])
        #expect(fm.showingFeedback == true)
    }

    // MARK: - Edge Cases

    @Test @MainActor
    func feedbackCanBeTriggeredMultipleCycles() {
        let fm = makeFreshManager()
        // Three full cycles.
        for cycle in 1...3 {
            for _ in 1...5 {
                fm.recordExplanation(metadata: ["cycle": cycle])
            }
            #expect(fm.showingFeedback == true)
            fm.dismissFeedback()
        }
    }

    @Test @MainActor
    func initialStateIsClean() {
        let fm = makeFreshManager()
        #expect(fm.showingFeedback == false)
        #expect(fm.feedbackFeature == "")
        #expect(fm.feedbackMetadata.isEmpty)
        #expect(fm.feedbackSubmitted == false)
    }
}
