// KnowledgeCapability.swift — Knowledge Generation Runtime
//
// Stable capability declarations for knowledge generation jobs.
//
// Jobs declare what capability they require (e.g., "file summarization"),
// NOT which tier or provider should execute it. The capability resolver
// maps capabilities to execution strategies at wiring time.
//
// This separation allows deterministic implementations to replace AI
// without changing job declarations, planner logic, or runtime scheduling.

import Foundation

// MARK: - Capability Declaration

/// A stable capability that a knowledge generation job requires.
///
/// Jobs declare their required capability. The capability resolver
/// (configured at startup) maps each capability to a tier and executor.
///
/// New capabilities are added as cases. Existing cases are stable —
/// changing a case name is a breaking change for all registered jobs.
enum KnowledgeCapability: String, Sendable, Codable, CaseIterable {
    /// Summarize structured facts about a source file into natural language.
    case fileSummarization

    /// Analyze behavioral patterns from structural data.
    case behaviorAnalysis

    /// Assess safety characteristics from structural data.
    case safetyAssessment

    /// Interpret architectural design from structural data.
    case designInterpretation

    /// Compress text while preserving key technical facts.
    case textCompression

    /// Summarize module-level structural properties.
    case moduleSummarization

    /// Summarize system/project-level architectural properties.
    case architectureSummarization
}

// MARK: - Capability Tier

/// Execution tier for a knowledge capability.
///
/// Ordered from cheapest to most expensive. The runtime prefers
/// the lowest tier capable of producing the required knowledge.
enum KnowledgeCapabilityTier: Int, Sendable, Codable, Comparable, CaseIterable {
    /// No AI needed — pure deterministic computation.
    case deterministic = 0

    /// Cheap, fast summarization model.
    case summarization = 1

    /// Medium reasoning capability.
    case reasoning = 2

    /// Full premium reasoning.
    case premium = 3

    static func < (lhs: KnowledgeCapabilityTier, rhs: KnowledgeCapabilityTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Capability Resolution

/// The result of resolving a capability to an execution strategy.
///
/// Produced by the capability resolver at wiring time. The runtime
/// uses this to determine whether AI is needed and which executor to call.
struct CapabilityResolution: Sendable {
    /// The tier assigned to this capability.
    let tier: KnowledgeCapabilityTier

    /// The executor for this capability. `nil` for deterministic capabilities
    /// (the job computes the result directly without external calls).
    let executor: CapabilityExecutor?
}

/// Closure that executes an AI capability request.
///
/// The runtime calls this when a job requires AI-tier execution.
/// The closure is injected by AppDependencies and routes to the
/// current AI provider. The KGR never imports AIProviderProtocol.
///
/// - Parameters:
///   - userContent: The structured input for the AI.
///   - systemPrompt: Instructions for the AI.
///   - capability: Which capability is being requested.
///   - mode: Analytics mode string (e.g., "enrichment").
/// - Returns: The AI-generated text response.
typealias CapabilityExecutor = @Sendable (
    _ userContent: String,
    _ systemPrompt: String,
    _ capability: KnowledgeCapability,
    _ mode: String
) async throws -> String

/// Resolves capabilities to execution strategies.
///
/// Configured once at startup in AppDependencies. The planner and runtime
/// consult this to determine how each capability should be fulfilled.
///
/// Phase 1: Simple switch-based resolution. All AI capabilities route
/// to the same provider. Future: per-capability model routing.
struct KnowledgeCapabilityResolver: Sendable {

    /// The resolution function. Maps a capability to a tier + executor.
    private let resolve: @Sendable (KnowledgeCapability) -> CapabilityResolution

    /// Creates a resolver with the given resolution function.
    init(resolve: @escaping @Sendable (KnowledgeCapability) -> CapabilityResolution) {
        self.resolve = resolve
    }

    /// Resolve a capability to its execution strategy.
    func resolution(for capability: KnowledgeCapability) -> CapabilityResolution {
        resolve(capability)
    }

    /// Convenience: the tier assigned to a capability.
    func tier(for capability: KnowledgeCapability) -> KnowledgeCapabilityTier {
        resolve(capability).tier
    }

    // MARK: - Factory

    /// Creates a resolver where all AI capabilities use the same executor.
    ///
    /// Phase 1 default. All non-deterministic capabilities route to
    /// a single AI provider via the shared executor closure.
    static func uniform(executor: @escaping CapabilityExecutor) -> KnowledgeCapabilityResolver {
        KnowledgeCapabilityResolver { capability in
            switch capability {
            case .fileSummarization, .behaviorAnalysis, .safetyAssessment,
                 .designInterpretation, .textCompression:
                return CapabilityResolution(tier: .summarization, executor: executor)
            case .moduleSummarization, .architectureSummarization:
                // These will be deterministic in Phase 2, but the capability
                // exists now for forward compatibility.
                return CapabilityResolution(tier: .deterministic, executor: nil)
            }
        }
    }

    /// Creates a resolver where all capabilities are deterministic.
    /// Used in tests and when no AI provider is available.
    static let allDeterministic = KnowledgeCapabilityResolver { _ in
        CapabilityResolution(tier: .deterministic, executor: nil)
    }
}
