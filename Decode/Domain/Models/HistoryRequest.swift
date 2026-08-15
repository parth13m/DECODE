// HistoryRequest.swift — Decode Domain
//
// Data models for the History feature — the 10 most recent explanation
// requests with their follow-up conversations.
//
// All models are Codable, Sendable, and value types — suitable for JSON
// persistence following the SessionState pattern.

import Foundation

// MARK: - HistoryFollowUp

/// A single follow-up question and its answer within a history request.
struct HistoryFollowUp: Identifiable, Codable, Sendable, Equatable {

    let id: UUID
    let createdAt: Date
    let question: String
    let answer: String
}

// MARK: - HistoryRequest

/// A single explanation request with its original context and follow-up
/// conversation. Self-contained — renders even if the original workspace
/// or file no longer exists.
struct HistoryRequest: Identifiable, Codable, Sendable, Equatable {

    let id: UUID
    let createdAt: Date

    // Original request context
    let mode: String
    let originalCode: String
    let explanation: String

    // Optional display metadata
    let sourceAppName: String?
    let fileName: String?
    let language: String?
    let explanationProfile: String?

    /// The user's custom question / personalized query, if one was typed
    /// during intent collection. `nil` when the user pressed Enter/Space
    /// for a default explanation (no custom question).
    let customQuestion: String?

    // Follow-up conversation (ordered by creation time)
    var followUps: [HistoryFollowUp]

    /// Maximum number of history requests retained.
    static let maxItemCount = 10
}
