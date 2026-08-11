// ConsumerRuntimeTypes.swift — ConsumerRuntime
// DDS-009: Consumer Runtime types
// IAG-001 §2: M6 ConsumerRuntime value types

import Foundation
import DIRCore
import ContextAssembly

// MARK: — Output Specification

/// Declares what kind of understanding a consumer should produce.
///
/// DDS-009 PC-1: The output specification is part of the consumer request.
/// It declares purpose, output class, and constraints.
public struct OutputSpecification: Sendable {
    /// The purpose this understanding should address.
    public let purpose: ContextPurpose

    /// The output class (human-facing, machine-facing, or hybrid).
    public let outputClass: OutputClass

    /// Maximum output length (optional constraint).
    public let maxLength: Int?

    /// Detail level (optional constraint).
    public let detailLevel: DetailLevel

    /// Whether this is a follow-up in a conversation.
    public let isFollowUp: Bool

    /// Optional advisory profile context to append to the system prompt.
    /// Produced by ``ProfilePromptFormatter``. `nil` means no profile available.
    public let profileContext: String?

    /// Optional raw selected source code snippet from the user's editor.
    /// Included in the user prompt so the LLM can see the actual code alongside
    /// structured DIR evidence. `nil` when no specific snippet was selected.
    public let snippetText: String?

    /// Optional pre-generated semantic understanding (behavior, safety, design)
    /// from the Knowledge Generation Runtime. Included in the user prompt so the
    /// reasoning engine can leverage proactively computed File Understanding.
    /// `nil` when no semantic enrichment is available for the target file.
    public let semanticContext: String?

    public init(
        purpose: ContextPurpose,
        outputClass: OutputClass = .human,
        maxLength: Int? = nil,
        detailLevel: DetailLevel = .standard,
        isFollowUp: Bool = false,
        profileContext: String? = nil,
        snippetText: String? = nil,
        semanticContext: String? = nil
    ) {
        self.purpose = purpose
        self.outputClass = outputClass
        self.maxLength = maxLength
        self.detailLevel = detailLevel
        self.isFollowUp = isFollowUp
        self.profileContext = profileContext
        self.snippetText = snippetText
        self.semanticContext = semanticContext
    }
}

/// The output class of understanding.
///
/// DDS-009 PC-1: Human, machine, or hybrid output.
public enum OutputClass: String, Hashable, Sendable {
    case human
    case machine
    case hybrid
}

/// The detail level of understanding output.
///
/// DDS-009 PC-1: Output constraint.
public enum DetailLevel: String, Hashable, Sendable {
    case minimal
    case standard
    case detailed
}

// MARK: — Consumer Request

/// The input to a consumer invocation.
///
/// DDS-009 PC-1: Context frame + output specification + optional conversation state.
public struct ConsumerRequest: Sendable {
    /// The context frame (output of DDS-006:PC-1).
    public let contextFrame: ContextFrame

    /// What kind of understanding to produce.
    public let outputSpecification: OutputSpecification

    /// Conversation state from a prior invocation (nil for first interactions).
    public let conversationState: ConversationState?

    public init(
        contextFrame: ContextFrame,
        outputSpecification: OutputSpecification,
        conversationState: ConversationState? = nil
    ) {
        self.contextFrame = contextFrame
        self.outputSpecification = outputSpecification
        self.conversationState = conversationState
    }
}

// MARK: — Conversation State

/// Opaque, serializable, bounded record carrying the context of prior interactions.
///
/// DDS-009 CL-4: Opaque to the pipeline — only reasoning engines read/write content.
/// DDS-009 CL-5: Bounded — the Consumer Runtime enforces a size limit.
/// DDS-009 RI-9: Transient — never persisted, destroyed with the Consumer Runtime.
public struct ConversationState: Sendable {
    /// Opaque data produced by the reasoning engine.
    public let data: Data

    /// The engine identifier that produced this state.
    public let engineIdentifier: String

    /// The engine version that produced this state.
    public let engineVersion: String

    /// Size in bytes.
    public var sizeBytes: Int { data.count }

    public init(data: Data, engineIdentifier: String, engineVersion: String) {
        self.data = data
        self.engineIdentifier = engineIdentifier
        self.engineVersion = engineVersion
    }

    /// Maximum conversation state size (DDS-009 CL-5, RI-7).
    /// 256 KB — sufficient for conversation context, bounded for memory safety.
    public static let maxSizeBytes: Int = 256 * 1024
}

// MARK: — Claim Types

/// A type of understanding claim.
///
/// DDS-009 PC-1: Claims are typed — factual, derived, interpretive, or inferred.
public enum ClaimType: String, Hashable, Sendable {
    /// Directly stated in the evidence — deterministic.
    case factual
    /// Computed from evidence by deterministic logic.
    case derived
    /// Interpretation requiring judgment.
    case interpretive
    /// Inferred from indirect evidence.
    case inferred
}

/// A discrete assertion within an understanding.
///
/// DDS-009 PC-1, UC-1, UC-3: Each claim is traceable to specific context frame units.
/// DDS-009 GP-1: Every claim references at least one context frame unit.
/// DDS-009 CP-2: Claim confidence does not exceed grounding evidence tier.
public struct UnderstandingClaim: Sendable {
    /// The assertion text.
    public let content: String

    /// The type of claim.
    public let claimType: ClaimType

    /// Confidence level of this claim.
    public let confidence: Confidence

    /// Context frame unit IDs that ground this claim (GP-1: at least one).
    public let groundingReferences: [UnitIdentifier]

    public init(
        content: String,
        claimType: ClaimType,
        confidence: Confidence,
        groundingReferences: [UnitIdentifier]
    ) {
        self.content = content
        self.claimType = claimType
        self.confidence = confidence
        self.groundingReferences = groundingReferences
    }
}

// MARK: — Completeness Assessment

/// How complete the understanding is relative to the evidence.
///
/// DDS-009 UC-4, RI-5: Honestly reported — never claims complete when evidence is insufficient.
public enum CompletenessAssessment: String, Hashable, Sendable {
    /// All evidence was used, understanding is comprehensive.
    case complete
    /// Some evidence was insufficient, understanding is partial.
    case partial
    /// Evidence was substantially insufficient.
    case insufficient
}

// MARK: — Understanding Metadata

/// Metadata describing an understanding's composition and quality.
///
/// DDS-009 PC-1: Purpose, output class, engine identifier, context frame epoch,
/// degradation level, reasoning duration, grounding coverage, tier distribution,
/// completeness assessment.
public struct UnderstandingMetadata: Sendable {
    /// The purpose addressed.
    public let purpose: ContextPurpose

    /// The output class produced.
    public let outputClass: OutputClass

    /// The reasoning engine that produced this understanding.
    public let engineIdentifier: String

    /// The engine version.
    public let engineVersion: String

    /// The context frame's committed epoch.
    public let contextFrameEpoch: Epoch

    /// Tier degradation level from the context frame.
    public let degradationLevel: DegradationLevel

    /// Wall-clock reasoning duration.
    public let reasoningDuration: TimeInterval

    /// Fraction of context frame units referenced by at least one claim (GP-3).
    public let groundingCoverage: Double

    /// Per-tier claim counts.
    public let tierDistribution: [Tier: Int]

    /// Completeness assessment.
    public let completeness: CompletenessAssessment

    /// Whether a fallback engine was used (FM-1).
    public let usedFallback: Bool

    /// Whether the context frame was stale (FM-7).
    public let isStale: Bool

    /// Number of claims removed due to grounding failure.
    public let ungroundedClaimsRemoved: Int

    /// Number of claims whose confidence was capped.
    public let confidenceAdjustments: Int

    /// Whether conversation state was discarded (FM-5).
    public let conversationStateDiscarded: Bool

    public init(
        purpose: ContextPurpose,
        outputClass: OutputClass,
        engineIdentifier: String,
        engineVersion: String,
        contextFrameEpoch: Epoch,
        degradationLevel: DegradationLevel,
        reasoningDuration: TimeInterval,
        groundingCoverage: Double,
        tierDistribution: [Tier: Int],
        completeness: CompletenessAssessment,
        usedFallback: Bool = false,
        isStale: Bool = false,
        ungroundedClaimsRemoved: Int = 0,
        confidenceAdjustments: Int = 0,
        conversationStateDiscarded: Bool = false
    ) {
        self.purpose = purpose
        self.outputClass = outputClass
        self.engineIdentifier = engineIdentifier
        self.engineVersion = engineVersion
        self.contextFrameEpoch = contextFrameEpoch
        self.degradationLevel = degradationLevel
        self.reasoningDuration = reasoningDuration
        self.groundingCoverage = groundingCoverage
        self.tierDistribution = tierDistribution
        self.completeness = completeness
        self.usedFallback = usedFallback
        self.isStale = isStale
        self.ungroundedClaimsRemoved = ungroundedClaimsRemoved
        self.confidenceAdjustments = confidenceAdjustments
        self.conversationStateDiscarded = conversationStateDiscarded
    }
}

// MARK: — Understanding

/// The output of consumer reasoning: grounded, confidence-annotated, purpose-specific.
///
/// DDS-009 PC-1: Content, claims, metadata, optional conversation state.
/// DAS-001 P6: Understanding is transient — derived, not stored.
public struct Understanding: Sendable {
    /// Purpose-specific output content.
    public let content: String

    /// Discrete assertions with grounding references and confidence.
    public let claims: [UnderstandingClaim]

    /// Composition and quality metadata.
    public let metadata: UnderstandingMetadata

    /// Conversation state for follow-up continuity (nil if no conversation).
    public let conversationState: ConversationState?

    public init(
        content: String,
        claims: [UnderstandingClaim],
        metadata: UnderstandingMetadata,
        conversationState: ConversationState? = nil
    ) {
        self.content = content
        self.claims = claims
        self.metadata = metadata
        self.conversationState = conversationState
    }
}

// MARK: — Consumer Result

/// The result of a consumer invocation.
///
/// DDS-009 PC-1: Either a valid understanding or a failure with diagnostic context.
/// DAS-011 CL-3: Invocation atomicity — success or failure, no partial state.
public enum ConsumerResult: Sendable {
    /// A valid understanding (possibly degraded).
    case success(Understanding)
    /// A failure with diagnostic context.
    case failure(ConsumerFailure)
}

// MARK: — Consumer Failure

/// A consumer invocation failure with diagnostic context.
///
/// DDS-009 FM-1 through FM-7, RI-8: Every failure is diagnosable.
public struct ConsumerFailure: Sendable {
    /// The failure mode.
    public let mode: ConsumerFailureMode

    /// Human-readable diagnostic.
    public let diagnostic: String

    /// The purpose that was requested.
    public let requestedPurpose: ContextPurpose

    /// Available purposes in the registry (for FM-6).
    public let availablePurposes: [ContextPurpose]

    public init(
        mode: ConsumerFailureMode,
        diagnostic: String,
        requestedPurpose: ContextPurpose,
        availablePurposes: [ContextPurpose] = []
    ) {
        self.mode = mode
        self.diagnostic = diagnostic
        self.requestedPurpose = requestedPurpose
        self.availablePurposes = availablePurposes
    }
}

/// Failure modes per DDS-009.
public enum ConsumerFailureMode: String, Hashable, Sendable {
    /// FM-1: Reasoning engine failure (and no fallback succeeded).
    case engineFailure
    /// FM-2: Validation failure (malformed request).
    case validationFailure
    /// FM-3: All claims ungrounded.
    case groundingFailure
    /// FM-4: Reasoning budget exhausted with no usable output.
    case budgetExhaustion
    /// FM-5: Conversation state corruption (invocation succeeds as new conversation).
    /// Note: FM-5 produces a success with metadata flag, not a failure.
    /// This mode exists for completeness but is typically not surfaced as a failure.
    case conversationStateCorruption
    /// FM-6: No reasoning engine registered for the purpose.
    case engineNotFound
    /// FM-7: Context staleness (invocation succeeds with staleness flag).
    /// Note: FM-7 produces a success with metadata flag, not a failure.
    case contextStaleness
    /// Consumer Runtime is terminated.
    case terminated
}

// MARK: — Reasoning Engine Output

/// Raw output from a reasoning engine before verification.
///
/// DDS-009 Execution Model: Produced by reasoning engines, verified by ConsumerRuntime.
public struct ReasoningEngineOutput: Sendable {
    /// The content produced by reasoning.
    public let content: String

    /// Raw claims before grounding/confidence verification.
    public let claims: [UnderstandingClaim]

    /// Completeness assessment from the engine.
    public let completeness: CompletenessAssessment

    /// Conversation state for follow-up continuity.
    public let conversationState: ConversationState?

    public init(
        content: String,
        claims: [UnderstandingClaim],
        completeness: CompletenessAssessment,
        conversationState: ConversationState? = nil
    ) {
        self.content = content
        self.claims = claims
        self.completeness = completeness
        self.conversationState = conversationState
    }
}

// MARK: — Engine Registration

/// A reasoning engine registration entry.
///
/// DDS-009 PC-2: Purpose, engine identifier, fallback designation.
public struct EngineRegistration: Sendable {
    /// The purpose this engine serves.
    public let purpose: ContextPurpose

    /// Unique, stable engine identifier (includes version).
    public let engineIdentifier: String

    /// Engine version.
    public let engineVersion: String

    /// The reasoning engine implementation.
    public let engine: ReasoningEngine

    /// Whether this is a fallback engine for its purpose.
    public let isFallback: Bool

    public init(
        purpose: ContextPurpose,
        engineIdentifier: String,
        engineVersion: String,
        engine: ReasoningEngine,
        isFallback: Bool = false
    ) {
        self.purpose = purpose
        self.engineIdentifier = engineIdentifier
        self.engineVersion = engineVersion
        self.engine = engine
        self.isFallback = isFallback
    }
}

// MARK: — Engine Catalog Entry

/// A catalog entry describing a registered reasoning engine.
///
/// DDS-009 PC-3: Active engine with identifier, version, and fallback designation.
public struct EngineCatalogEntry: Sendable {
    /// The engine identifier.
    public let engineIdentifier: String

    /// The engine version.
    public let engineVersion: String

    /// Whether a fallback engine is designated for this purpose.
    public let hasFallback: Bool

    /// The fallback engine identifier (if any).
    public let fallbackIdentifier: String?

    public init(
        engineIdentifier: String,
        engineVersion: String,
        hasFallback: Bool = false,
        fallbackIdentifier: String? = nil
    ) {
        self.engineIdentifier = engineIdentifier
        self.engineVersion = engineVersion
        self.hasFallback = hasFallback
        self.fallbackIdentifier = fallbackIdentifier
    }
}

// MARK: — Consumer Runtime State

/// Lifecycle state of the Consumer Runtime.
///
/// DDS-009 State Model: Unavailable → Available → Terminated.
public enum ConsumerRuntimeState: String, Hashable, Sendable {
    case unavailable
    case available
    case terminated

    public func canTransition(to target: ConsumerRuntimeState) -> Bool {
        switch (self, target) {
        case (.unavailable, .available): return true
        case (.available, .terminated): return true
        default: return false
        }
    }
}
