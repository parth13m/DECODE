// KnowledgePolicy.swift — Knowledge Generation Runtime
//
// Decides WHETHER knowledge generation should occur.
// Separate from the Planner, which decides WHAT work is required.
//
// The Policy evaluates environmental conditions (user preferences,
// AI availability, tier restrictions) and returns allow/defer/prohibit
// decisions that the Planner respects.
//
// Phase 1: Simple defaults (enabled toggle, AI availability, max tier).
// Future: battery awareness, enterprise policy, network state, cost budgets.

import Foundation

// MARK: - Policy Decision

/// The result of a policy evaluation.
///
/// The planner consults the policy before emitting work items.
/// `.allow` means the work can proceed. `.defer` means the work
/// should be saved but not executed yet. `.prohibit` means skip entirely.
enum KnowledgePolicyDecision: Sendable, Equatable {
    /// Work is allowed to proceed.
    case allow
    /// Work should be deferred until conditions change.
    case `defer`
    /// Work is prohibited and should not be enqueued.
    case prohibit
}

// MARK: - Knowledge Policy

/// Evaluates whether knowledge generation should occur.
///
/// The policy is consulted by the planner before producing work items.
/// It does not know about specific jobs — it evaluates environmental
/// conditions against requested capability tiers.
///
/// ## Phase 1
/// - `isEnabled`: user toggle (UserDefaults)
/// - `isAIAvailable`: whether an AI provider is configured
/// - `maximumAllowedTier`: ceiling on capability tiers
///
/// ## Future Extensions (no API change needed)
/// - Battery awareness: lower max tier on battery
/// - Network state: defer AI work when offline
/// - Cost budgeting: prohibit when budget exhausted
/// - Enterprise restrictions: tier ceilings from MDM
struct KnowledgePolicy: Sendable {

    /// Whether background knowledge generation is enabled.
    /// When false, all work is prohibited.
    let isEnabled: Bool

    /// Whether AI-tier capabilities are currently available.
    /// When false, only deterministic work is allowed.
    let isAIAvailable: Bool

    /// The maximum capability tier allowed in current conditions.
    /// Work requiring a higher tier is deferred (not prohibited),
    /// because conditions may change (e.g., AI becomes available).
    let maximumAllowedTier: KnowledgeCapabilityTier

    // MARK: - Evaluation

    /// Evaluate whether work at a given tier should proceed.
    ///
    /// - Parameter requiredTier: The tier needed by the work item.
    /// - Returns: The policy decision.
    func evaluate(requiredTier: KnowledgeCapabilityTier) -> KnowledgePolicyDecision {
        // Global kill switch.
        guard isEnabled else {
            return .prohibit
        }

        // AI-tier work when AI is unavailable: defer, not prohibit.
        // The provider may become available later (auth completes, network returns).
        if requiredTier > .deterministic && !isAIAvailable {
            return .defer
        }

        // Tier ceiling: defer work above the maximum.
        if requiredTier > maximumAllowedTier {
            return .defer
        }

        return .allow
    }

    // MARK: - Factory

    /// Creates a policy that reads live state from the environment.
    ///
    /// - Parameters:
    ///   - enabledKey: UserDefaults key for the enabled toggle.
    ///   - aiAvailable: Whether an AI provider is currently configured.
    static func live(
        enabledKey: String = "knowledgeGenerationEnabled",
        aiAvailable: Bool
    ) -> KnowledgePolicy {
        let enabled = UserDefaults.standard.bool(forKey: enabledKey)
        return KnowledgePolicy(
            isEnabled: enabled,
            isAIAvailable: aiAvailable,
            maximumAllowedTier: .summarization  // Phase 1: cap at summarization
        )
    }

    /// Default policy for testing: everything enabled, AI available.
    static let allAllowed = KnowledgePolicy(
        isEnabled: true,
        isAIAvailable: true,
        maximumAllowedTier: .premium
    )

    /// Policy that prohibits all work.
    static let disabled = KnowledgePolicy(
        isEnabled: false,
        isAIAvailable: false,
        maximumAllowedTier: .deterministic
    )

    /// Policy that allows only deterministic work.
    static let deterministicOnly = KnowledgePolicy(
        isEnabled: true,
        isAIAvailable: false,
        maximumAllowedTier: .deterministic
    )
}
