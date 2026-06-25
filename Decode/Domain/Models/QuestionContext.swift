import Foundation

/// Metadata about the most recent question Decode answered for a session.
///
/// Captures the reasoning decisions the coordinator made: which context tier
/// was used, which understanding layers were selected, snippet health, and
/// prompt size. Stored on ``ManagedSession`` so the Knowledge Inspector can
/// show "How Decode Reasons" without triggering any computation.
struct QuestionContext: Sendable {
    let contextTier: String
    let includedBehavior: Bool
    let includedSafety: Bool
    let includedDesign: Bool
    let healthTier: String
    let healthHintCount: Int
    let promptCharacterCount: Int
    let enrichmentCacheHit: Bool
    let timestamp: Date
}
