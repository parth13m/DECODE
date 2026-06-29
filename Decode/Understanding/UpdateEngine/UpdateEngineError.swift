// UpdateEngineError.swift — UpdateEngine
// DDS-007: FM-1 through FM-6 failure modes
// DDS-002: FM-1 through FM-5 DIR runtime failure modes

import Foundation
import DIRCore

/// Errors from the Update Engine subsystem.
///
/// Maps to DDS-007 FM-1 through FM-6 and DDS-002 FM-1 through FM-5.
public enum UpdateEngineError: Error, Sendable {

    // MARK: — DDS-002 DIR Runtime Failures

    /// FM-1: Intake validation failure. Unit(s) failed structural/contractual checks.
    case intakeValidationFailed(violations: [IntakeViolation])

    /// FM-2: Invalid status transition attempted.
    case invalidStatusTransition(unitId: UnitIdentifier, from: UnitStatus, to: UnitStatus)

    /// FM-3: Unit not found for status transition.
    case unitNotFound(UnitIdentifier)

    /// FM-4: Two units with the same supersession key in the same transaction.
    case supersessionConflict(key: SupersessionKey)

    /// FM-5: Memory exhaustion — unit store exceeds capacity.
    case memoryExhausted

    // MARK: — DDS-007 Update Engine Failures

    /// FM-1: Frontend parse failure for a changed file.
    case frontendParseFailed(filePath: String, detail: String)

    /// FM-2: Synchronous pass failure during pipeline execution.
    case synchronousPassFailed(producerId: String, detail: String)

    /// FM-3: Deferred T2 recomputation failure.
    case deferredRecomputationFailed(unitId: UnitIdentifier, detail: String)

    /// FM-4: Invalidation transaction rejected (unit already in correct state).
    case invalidationRejected(unitId: UnitIdentifier, detail: String)

    /// FM-5: Index update failure during pipeline.
    case indexUpdateFailed(detail: String)

    /// FM-6: Grounding dependency map unavailable during cascade.
    case groundingMapUnavailable

    /// Invalid state for the requested operation.
    case invalidState(current: UpdateEngineState, attempted: String)

    /// The engine is not in an operational state.
    case notOperational
}
