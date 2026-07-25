// ContextAssemblyProtocols.swift — ContextAssembly
// DDS-006: PC-1 (Context Assembly), PC-2 (Strategy Registration), PC-3 (Strategy Catalog Query)
// IAG-001 §4: Defined in ContextAssembly, consumed by ConsumerRuntime
// IAG-003 §1.2: Stateless — no actor
// IAG-003 §3.1: async — crosses module boundary

import Foundation
import DIRCore
import RetrievalRuntime

/// Transforms an evidence set into a purpose-calibrated, budget-constrained context frame.
///
/// DDS-006 PC-1: Given an assembly request (evidence set, context purpose, budget,
/// optional strategy version), produces a context frame satisfying CFI-1 through CFI-9.
///
/// Stateless — no persistent state between requests (IAG-003 §1.2).
/// Each request resolves its own strategy and maintains its own selection state.
public protocol ContextAssembling: Sendable {

    /// Assembles a context frame from an evidence set per the strategy for the given purpose.
    ///
    /// DDS-006 PC-1: Executes the 10-phase assembly pipeline:
    /// precondition validation → strategy resolution → budget computation →
    /// stratum-ordered selection → cross-stratum coherence → deduplication →
    /// within-stratum ordering → metadata assembly → frame construction → return.
    ///
    /// Never throws. Returns either a valid context frame (possibly empty or partial)
    /// or a rejection with diagnostic.
    ///
    /// - Parameter request: The assembly request specifying evidence set, purpose, budget.
    /// - Returns: Assembly result — success with context frame or rejection with diagnostic.
    func assemble(_ request: AssemblyRequest) async -> AssemblyResult
}

/// Manages the strategy catalog — validation, registration, versioning, and querying.
///
/// DDS-006 PC-2: Validates strategies against SI-1 through SI-7 and registers valid strategies.
/// DDS-006 PC-3: Returns the current strategy catalog.
///
/// Strategy catalog is session-scoped — strategies are loaded at startup and discarded
/// at shutdown. No persistent strategy state survives across restarts.
public protocol StrategyManagement: Sendable {

    /// Registers a context strategy after validating all strategy invariants.
    ///
    /// DDS-006 PC-2: Validates SI-1 (budget fraction totality), SI-2 (selection criteria
    /// mutual exclusivity), SI-3 (priority uniqueness), SI-4 (coherence constraint
    /// termination), SI-5 (essential stratum singularity), SI-7 (stratum reachability).
    ///
    /// SI-6 (strategy-purpose bijection) is enforced by the catalog: if a strategy for the
    /// same purpose already exists, the new strategy supersedes it. The prior version is
    /// retained for diagnostic replay.
    ///
    /// - Parameter strategy: The context strategy to validate and register.
    /// - Returns: Success if valid and registered; failure with the specific validation error.
    func register(_ strategy: ContextStrategy) -> Result<Void, StrategyValidationError>

    /// Returns the current strategy catalog: purpose → active strategy.
    ///
    /// DDS-006 PC-3: Includes active strategies only. Superseded versions are available
    /// for assembly via strategy version override but are not returned here.
    ///
    /// Always succeeds — returns empty dictionary if no strategies are registered.
    func strategyCatalog() -> [ContextPurpose: ContextStrategy]
}
