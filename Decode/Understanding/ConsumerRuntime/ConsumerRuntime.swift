// ConsumerRuntime.swift — ConsumerRuntime
// DDS-009: Consumer Runtime — reasoning engine management, grounding verification,
//          consumer invocation, demand signaling
// IAG-001 §2: M6 ConsumerRuntime
// IAG-003 §2.4: ConsumerActor owns reasoning engine registry, conversation state,
//               demand signal deduplication state

import Foundation
import DIRCore
import ContextAssembly
import os

/// The core actor of the Consumer Runtime.
///
/// IAG-003 §2.4: Owns the reasoning engine registry, demand signal deduplication state.
/// DDS-009: Terminal pipeline module — consumes context frames, produces understanding.
///
/// Concurrency model:
/// - Consumer invocations (DDS-009:PC-1) enter the actor for engine resolution, then
///   reasoning proceeds concurrently. Multiple concurrent invocations are permitted.
/// - Engine registration (DDS-009:PC-2, PC-3) serializes with reads via the actor boundary.
/// - Demand signal emission (DDS-009:PC-4) is fire-and-forget, does not block invocations.
public actor ConsumerActor: ConsumerInvocation, ReasoningEngineManagement {

    // MARK: — Dependencies

    /// Demand signal sink for T2 recomputation requests (DDS-009:PC-4 → DDS-007:PC-2).
    /// Optional — demand signaling is best-effort. Nil during startup or when UpdateEngine
    /// is unavailable.
    private let demandSignalSink: DemandSignalSink?

    // MARK: — Owned State: Reasoning Engine Registry

    /// Active engines: purpose → registration.
    /// DDS-009 PC-2: One active engine per purpose.
    private var activeEngines: [ContextPurpose: EngineRegistration] = [:]

    /// Fallback engines: purpose → registration.
    /// DDS-009 FM-1: Invoked when the primary engine fails.
    private var fallbackEngines: [ContextPurpose: EngineRegistration] = [:]

    // MARK: — Owned State: Demand Signal Deduplication

    /// Recently signaled entities: entity qualified name → expiry time.
    /// DDS-009 PC-4: Deduplication prevents redundant signals within the window.
    private var demandDeduplication: [String: Date] = [:]

    /// Deduplication window duration (default: 30 seconds per DDS-009 Memory and Ownership).
    private let deduplicationWindowSeconds: TimeInterval = 30.0

    // MARK: — Owned State: Runtime

    /// Current lifecycle state.
    private var state: ConsumerRuntimeState = .unavailable

    // MARK: — Logging

    private let logger = Logger(subsystem: "com.decode.understanding", category: "consumer")

    // MARK: — Initialization

    /// Creates a ConsumerActor.
    ///
    /// IAG-001 §6: ConsumerRuntime receives DemandSignalSink from the composition root.
    /// DDS-009 Lifecycle: Created during application startup. No persistent state.
    ///
    /// - Parameter demandSignalSink: Optional sink for T2 demand signals.
    public init(demandSignalSink: DemandSignalSink? = nil) {
        self.demandSignalSink = demandSignalSink
        logger.debug("ConsumerActor created — state: unavailable")
    }

    // MARK: — Lifecycle

    /// Transitions to Available state.
    ///
    /// DDS-009 Lifecycle: The runtime enters Available state and begins accepting
    /// consumer requests. May be called with an empty registry — requests for
    /// unregistered purposes will fail with FM-6.
    public func activate() {
        guard state.canTransition(to: .available) else {
            logger.warning("activate called in state: \(self.state.rawValue) — ignoring")
            return
        }
        state = .available
        logger.info("ConsumerActor activated — state: available")
    }

    /// Initiates shutdown.
    ///
    /// DDS-009 Lifecycle: No new consumer requests accepted. In-progress invocations
    /// complete normally. Registry discarded.
    public func shutdown() {
        guard state.canTransition(to: .terminated) else {
            logger.warning("shutdown called in state: \(self.state.rawValue) — ignoring")
            return
        }
        state = .terminated
        activeEngines.removeAll()
        fallbackEngines.removeAll()
        demandDeduplication.removeAll()
        logger.info("ConsumerActor terminated — registry discarded")
    }

    // MARK: — ReasoningEngineManagement (PC-2, PC-3)

    public func register(_ registration: EngineRegistration) async -> Bool {
        guard state != .terminated else {
            logger.warning("register called in terminated state — rejecting")
            return false
        }

        guard !registration.engineIdentifier.isEmpty else {
            logger.warning("register called with empty engine identifier — rejecting")
            return false
        }

        if registration.isFallback {
            fallbackEngines[registration.purpose] = registration
            logger.info("Fallback engine registered: \(registration.engineIdentifier) for purpose \(registration.purpose.identifier)")
        } else {
            activeEngines[registration.purpose] = registration
            logger.info("Engine registered: \(registration.engineIdentifier) for purpose \(registration.purpose.identifier)")
        }

        return true
    }

    public func engineCatalog() async -> [ContextPurpose: EngineCatalogEntry] {
        var catalog: [ContextPurpose: EngineCatalogEntry] = [:]
        for (purpose, registration) in activeEngines {
            let fallback = fallbackEngines[purpose]
            catalog[purpose] = EngineCatalogEntry(
                engineIdentifier: registration.engineIdentifier,
                engineVersion: registration.engineVersion,
                hasFallback: fallback != nil,
                fallbackIdentifier: fallback?.engineIdentifier
            )
        }
        return catalog
    }

    // MARK: — ConsumerInvocation (PC-1)

    public func invoke(_ request: ConsumerRequest) async -> ConsumerResult {
        // Phase 0: State check
        guard state == .available else {
            return .failure(ConsumerFailure(
                mode: .terminated,
                diagnostic: "Consumer Runtime is in state: \(state.rawValue)",
                requestedPurpose: request.outputSpecification.purpose
            ))
        }

        let startTime = ContinuousClock.now

        // Phase 1: Validation (DDS-009 Execution Model phase 1)
        if let validationFailure = validateRequest(request) {
            return .failure(validationFailure)
        }

        let purpose = request.outputSpecification.purpose

        // Phase 2: Engine Resolution (DDS-009 Execution Model phase 2)
        guard let registration = activeEngines[purpose] else {
            let available = Array(activeEngines.keys)
            return .failure(ConsumerFailure(
                mode: .engineNotFound,
                diagnostic: "No reasoning engine registered for purpose: \(purpose.identifier). Available: \(available.map(\.identifier).joined(separator: ", "))",
                requestedPurpose: purpose,
                availablePurposes: available
            ))
        }

        // Validate conversation state compatibility (FM-5)
        var effectiveConversationState = request.conversationState
        var conversationStateDiscarded = false
        if let convState = effectiveConversationState {
            if convState.engineIdentifier != registration.engineIdentifier {
                // Engine mismatch — discard state, proceed as new conversation
                effectiveConversationState = nil
                conversationStateDiscarded = true
                logger.info("Conversation state discarded — engine mismatch: \(convState.engineIdentifier) vs \(registration.engineIdentifier)")
            } else if convState.sizeBytes > ConversationState.maxSizeBytes {
                // Exceeds boundedness — discard
                effectiveConversationState = nil
                conversationStateDiscarded = true
                logger.info("Conversation state discarded — exceeds size limit: \(convState.sizeBytes) > \(ConversationState.maxSizeBytes)")
            }
        }

        // Phase 3: Reasoning (DDS-009 Execution Model phase 3)
        let engineOutput: ReasoningEngineOutput
        var usedFallback = false

        do {
            engineOutput = try await registration.engine.reason(
                contextFrame: request.contextFrame,
                outputSpecification: request.outputSpecification,
                conversationState: effectiveConversationState
            )
        } catch {
            // FM-1: Reasoning engine failure — try fallback
            logger.error("Primary engine \(registration.engineIdentifier) failed: \(error.localizedDescription)")

            if let fallback = fallbackEngines[purpose] {
                do {
                    engineOutput = try await fallback.engine.reason(
                        contextFrame: request.contextFrame,
                        outputSpecification: request.outputSpecification,
                        conversationState: nil // Fallback starts fresh
                    )
                    usedFallback = true
                    logger.info("Fallback engine \(fallback.engineIdentifier) succeeded")
                } catch {
                    logger.error("Fallback engine \(fallback.engineIdentifier) also failed: \(error.localizedDescription)")
                    return .failure(ConsumerFailure(
                        mode: .engineFailure,
                        diagnostic: "Primary engine \(registration.engineIdentifier) and fallback engine \(fallback.engineIdentifier) both failed. Primary error: \(error.localizedDescription)",
                        requestedPurpose: purpose
                    ))
                }
            } else {
                return .failure(ConsumerFailure(
                    mode: .engineFailure,
                    diagnostic: "Engine \(registration.engineIdentifier) failed: \(error.localizedDescription). No fallback engine designated.",
                    requestedPurpose: purpose
                ))
            }
        }

        // Build set of valid unit IDs from context frame for grounding verification
        let contextUnitIds = collectContextUnitIds(from: request.contextFrame)

        // Phase 4: Grounding Verification (DDS-009 Execution Model phase 4)
        var verifiedClaims: [UnderstandingClaim] = []
        var ungroundedCount = 0

        for claim in engineOutput.claims {
            let groundedRefs = claim.groundingReferences.filter { contextUnitIds.contains($0) }
            if groundedRefs.isEmpty {
                // Ungrounded claim — remove it
                ungroundedCount += 1
            } else {
                verifiedClaims.append(UnderstandingClaim(
                    content: claim.content,
                    claimType: claim.claimType,
                    confidence: claim.confidence,
                    groundingReferences: groundedRefs
                ))
            }
        }

        // FM-3: All claims ungrounded
        if verifiedClaims.isEmpty && !engineOutput.claims.isEmpty {
            return .failure(ConsumerFailure(
                mode: .groundingFailure,
                diagnostic: "All \(engineOutput.claims.count) claims were ungrounded — no claim references a context frame unit.",
                requestedPurpose: purpose
            ))
        }

        // Phase 5: Confidence Verification (DDS-009 Execution Model phase 5)
        var confidenceAdjustments = 0
        var confidenceVerifiedClaims: [UnderstandingClaim] = []

        for claim in verifiedClaims {
            let maxTier = maxGroundingTier(
                for: claim.groundingReferences,
                in: request.contextFrame
            )
            let cappedConfidence = capConfidence(claim.confidence, forTier: maxTier)

            if cappedConfidence != claim.confidence {
                confidenceAdjustments += 1
            }

            confidenceVerifiedClaims.append(UnderstandingClaim(
                content: claim.content,
                claimType: claim.claimType,
                confidence: cappedConfidence,
                groundingReferences: claim.groundingReferences
            ))
        }

        // Phase 6: Understanding Production (DDS-009 Execution Model phase 6)
        let elapsed = ContinuousClock.now - startTime
        let reasoningDuration = Double(elapsed.components.seconds) +
            Double(elapsed.components.attoseconds) / 1e18

        let groundingCoverage = contextUnitIds.isEmpty ? 0.0 :
            Double(referencedUnitCount(claims: confidenceVerifiedClaims, contextUnitIds: contextUnitIds)) /
            Double(contextUnitIds.count)

        let tierDistribution = computeTierDistribution(claims: confidenceVerifiedClaims)

        let engineReg = usedFallback ? (fallbackEngines[purpose] ?? registration) : registration

        let metadata = UnderstandingMetadata(
            purpose: purpose,
            outputClass: request.outputSpecification.outputClass,
            engineIdentifier: engineReg.engineIdentifier,
            engineVersion: engineReg.engineVersion,
            contextFrameEpoch: request.contextFrame.metadata.committedEpoch,
            degradationLevel: request.contextFrame.metadata.degradationLevel,
            reasoningDuration: reasoningDuration,
            groundingCoverage: groundingCoverage,
            tierDistribution: tierDistribution,
            completeness: engineOutput.completeness,
            usedFallback: usedFallback,
            isStale: false, // Staleness detection requires current DIR epoch — assessed by caller
            ungroundedClaimsRemoved: ungroundedCount,
            confidenceAdjustments: confidenceAdjustments,
            conversationStateDiscarded: conversationStateDiscarded
        )

        // Enforce conversation state boundedness (DDS-009 CL-5, RI-7)
        var outputConversationState = engineOutput.conversationState
        if let convState = outputConversationState,
           convState.sizeBytes > ConversationState.maxSizeBytes {
            // Truncate by discarding — DDS-009 says truncate or summarize.
            // At alpha scale, discard is acceptable. The engine should produce bounded state.
            outputConversationState = nil
            logger.warning("Output conversation state exceeds bound (\(convState.sizeBytes) bytes) — discarded")
        }

        let understanding = Understanding(
            content: engineOutput.content,
            claims: confidenceVerifiedClaims,
            metadata: metadata,
            conversationState: outputConversationState
        )

        // Consumer Demand Signaling (DDS-009 PC-4) — asynchronous, best-effort
        await emitDemandSignalsIfNeeded(contextFrame: request.contextFrame, purpose: purpose)

        logger.debug("Consumer invocation complete: purpose=\(purpose.identifier), claims=\(confidenceVerifiedClaims.count), coverage=\(groundingCoverage), duration=\(reasoningDuration)s")

        return .success(understanding)
    }

    // MARK: — Internal: Validation

    /// Validates a consumer request (DDS-009 Execution Model phase 1).
    private func validateRequest(_ request: ConsumerRequest) -> ConsumerFailure? {
        let purpose = request.outputSpecification.purpose

        // Context frame purpose must match output specification purpose
        if request.contextFrame.purpose != purpose {
            return ConsumerFailure(
                mode: .validationFailure,
                diagnostic: "Context frame purpose (\(request.contextFrame.purpose.identifier)) does not match output specification purpose (\(purpose.identifier)).",
                requestedPurpose: purpose
            )
        }

        // Context frame must have metadata
        // (ContextFrame struct guarantees this by construction, but check epoch validity)

        // Conversation state structural validation
        if let convState = request.conversationState {
            if convState.data.isEmpty {
                return ConsumerFailure(
                    mode: .validationFailure,
                    diagnostic: "Conversation state has empty data.",
                    requestedPurpose: purpose
                )
            }
        }

        return nil
    }

    // MARK: — Internal: Grounding Helpers

    /// Collects all unit IDs present in the context frame.
    private func collectContextUnitIds(from frame: ContextFrame) -> Set<UnitIdentifier> {
        var ids = Set<UnitIdentifier>()
        for stratum in frame.strata {
            for contextUnit in stratum.units {
                ids.insert(contextUnit.annotatedUnit.unit.id)
            }
        }
        return ids
    }

    /// Determines the highest (least deterministic) tier among grounding references.
    ///
    /// DDS-009 CP-2: Confidence cannot exceed the tier of the grounding evidence.
    /// Higher tier number = less deterministic.
    private func maxGroundingTier(
        for references: [UnitIdentifier],
        in frame: ContextFrame
    ) -> Tier {
        var maxTier: Tier = .t0
        for stratum in frame.strata {
            for contextUnit in stratum.units {
                if references.contains(contextUnit.annotatedUnit.unit.id) {
                    let tier = contextUnit.annotatedUnit.unit.tier
                    if tier > maxTier {
                        maxTier = tier
                    }
                }
            }
        }
        return maxTier
    }

    /// Caps confidence to not exceed tier-appropriate levels.
    ///
    /// DDS-009 CP-2, RI-2: Confidence monotonicity.
    /// T0 evidence → any confidence allowed (deterministic is most precise).
    /// T1 evidence → confidence ≤ high.
    /// T2 evidence → confidence ≤ high (T2 units cannot have deterministic confidence per DAS-003 I2).
    private func capConfidence(_ confidence: Confidence, forTier tier: Tier) -> Confidence {
        switch tier {
        case .t0:
            // T0 evidence supports any confidence level
            return confidence
        case .t1, .t2:
            // T1/T2 evidence cannot support deterministic confidence
            if confidence == .deterministic {
                return .high
            }
            return confidence
        }
    }

    /// Counts distinct unit IDs referenced by at least one claim.
    private func referencedUnitCount(
        claims: [UnderstandingClaim],
        contextUnitIds: Set<UnitIdentifier>
    ) -> Int {
        var referenced = Set<UnitIdentifier>()
        for claim in claims {
            for ref in claim.groundingReferences {
                if contextUnitIds.contains(ref) {
                    referenced.insert(ref)
                }
            }
        }
        return referenced.count
    }

    /// Computes per-tier claim counts.
    private func computeTierDistribution(claims: [UnderstandingClaim]) -> [Tier: Int] {
        var distribution: [Tier: Int] = [:]
        for claim in claims {
            // Map claim type to associated tier for distribution purposes
            let tier: Tier
            switch claim.claimType {
            case .factual: tier = .t0
            case .derived: tier = .t1
            case .interpretive, .inferred: tier = .t2
            }
            distribution[tier, default: 0] += 1
        }
        return distribution
    }

    // MARK: — Internal: Consumer Demand Signaling (PC-4)

    /// Emits demand signals for degraded T2 content if appropriate.
    ///
    /// DDS-009 Consumer Demand Signaling: Asynchronous, advisory, best-effort.
    /// Deduplicates signals within the configurable window.
    private func emitDemandSignalsIfNeeded(contextFrame: ContextFrame, purpose: ContextPurpose) async {
        guard let sink = demandSignalSink else { return }

        let degradation = contextFrame.metadata.degradationLevel
        guard degradation == .t0t1Only || degradation == .t0Only else { return }

        // Collect entity references from anchors — these are the entities with degraded T2
        let now = Date()

        // Purge expired deduplication entries
        demandDeduplication = demandDeduplication.filter { $0.value > now }

        for anchor in contextFrame.anchors {
            let key = anchor.qualifiedName

            // Deduplication check
            if let expiry = demandDeduplication[key], expiry > now {
                continue
            }

            // Emit demand signal
            let signal = DemandSignal(
                subject: .entity(anchor),
                predicate: PredicateIdentifier(name: "semantic_enrichment", domain: "understanding")
            )
            await sink.submit(signal)

            // Record in deduplication window
            demandDeduplication[key] = now.addingTimeInterval(deduplicationWindowSeconds)
        }
    }
}
