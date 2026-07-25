// ConsumerRuntimeProtocols.swift — ConsumerRuntime
// DDS-009: PC-1 (Consumer Invocation), PC-2/PC-3 (Reasoning Engine Management)
// IAG-001 §4: Defined in ConsumerRuntime, consumed by Application target
// IAG-003 §3.1: async — crosses ConsumerActor boundary

import Foundation
import DIRCore
import ContextAssembly

// MARK: — Consumer Invocation (PC-1)

/// Accepts consumer requests and produces understanding.
///
/// DDS-009 PC-1: Given a consumer request (context frame + output specification +
/// optional conversation state), produces an understanding satisfying UC-1 through UC-4.
///
/// IAG-003 §2.4: Implemented by ConsumerActor. All methods are async.
public protocol ConsumerInvocation: Sendable {

    /// Invokes a consumer with the given request.
    ///
    /// DDS-009 PC-1: 6-phase lifecycle — validation → engine resolution → reasoning →
    /// grounding verification → confidence verification → understanding production.
    ///
    /// Never throws. Returns either a valid understanding or a failure with diagnostic context.
    ///
    /// - Parameter request: The consumer request.
    /// - Returns: A consumer result — success with understanding or failure with diagnostic.
    func invoke(_ request: ConsumerRequest) async -> ConsumerResult
}

// MARK: — Reasoning Engine Management (PC-2, PC-3)

/// Manages the reasoning engine registry — registration, resolution, and catalog query.
///
/// DDS-009 PC-2: Register reasoning engines for purposes.
/// DDS-009 PC-3: Query the current engine catalog.
///
/// IAG-003 §2.4: Implemented by ConsumerActor. All methods are async.
public protocol ReasoningEngineManagement: Sendable {

    /// Registers a reasoning engine for a purpose.
    ///
    /// DDS-009 PC-2: If an engine already exists for the same purpose, the new engine
    /// replaces it. In-progress invocations using the prior engine complete normally.
    ///
    /// - Parameter registration: The engine registration entry.
    /// - Returns: True if registration succeeded, false if rejected.
    func register(_ registration: EngineRegistration) async -> Bool

    /// Returns the current engine catalog.
    ///
    /// DDS-009 PC-3: For each registered purpose, the active engine with identifier,
    /// version, and fallback designation.
    ///
    /// Always succeeds — returns empty dictionary if no engines are registered.
    func engineCatalog() async -> [ContextPurpose: EngineCatalogEntry]
}

// MARK: — Reasoning Engine

/// The contract that reasoning engines must satisfy.
///
/// DDS-009 Execution Model: Reasoning engines receive a context frame, output specification,
/// and conversation state. They produce raw understanding output. They do not access the DIR,
/// indexes, or file system (RB-5, RB-6).
///
/// DDS-009 CC-3, RI-3: Reasoning engines are stateless between invocations. Each invocation
/// is isolated.
public protocol ReasoningEngine: Sendable {

    /// Performs reasoning over the given context frame.
    ///
    /// DDS-009 RB-1 through RB-4: Purpose-specific reasoning producing raw understanding.
    /// The output will be verified by the Consumer Runtime (grounding, confidence).
    ///
    /// - Parameters:
    ///   - contextFrame: The context frame to reason over.
    ///   - outputSpecification: What kind of understanding to produce.
    ///   - conversationState: Prior conversation state (nil for first interactions).
    /// - Returns: Raw reasoning output for verification.
    /// - Throws: On reasoning engine failure (FM-1).
    func reason(
        contextFrame: ContextFrame,
        outputSpecification: OutputSpecification,
        conversationState: ConversationState?
    ) async throws -> ReasoningEngineOutput
}
