// UnitStore.swift — UpdateEngine / DIR
// DDS-002: R1 — unit store custody, R5 — identity assignment
// DDS-002: PC-1 (admission), PC-2 (transitions), PC-6 (write transactions)
// IAG-003 §2.1: Owned by UpdateActor — no independent concurrency

import Foundation
import DIRCore
import StorageEngine

/// Internal unit store managing all atomic units in the DIR.
///
/// DDS-002 R1: Exclusive custody of all atomic units.
/// DDS-002 R5: Assigns globally unique, monotonically increasing identifiers.
///
/// This struct is owned by `UpdateActor` and has no independent
/// thread safety — all access is serialized through the actor.
struct UnitStore: Sendable {

    // MARK: — Storage

    /// All units keyed by identifier.
    /// All units keyed by identifier. Internal setter for UpdateActor direct access.
    var units: [UnitIdentifier: AtomicUnit] = [:]

    /// Active units indexed by supersession key for O(1) lookup.
    private var activeByKey: [SupersessionKey: UnitIdentifier] = [:]

    /// Next unit identifier to assign. Monotonically increasing (DDS-002 IM-1).
    private(set) var nextUnitId: UInt64

    // MARK: — Initialization

    init(nextUnitId: UInt64 = 1) {
        self.nextUnitId = nextUnitId
    }

    // MARK: — Identity Assignment (R5)

    /// Assigns the next unique identifier.
    mutating func assignId() -> UnitIdentifier {
        let id = UnitIdentifier(rawValue: nextUnitId)
        nextUnitId += 1
        return id
    }

    // MARK: — Queries

    /// Returns the unit with the given identifier, or nil.
    func unit(for id: UnitIdentifier) -> AtomicUnit? {
        units[id]
    }

    /// Returns all active units.
    func activeUnits() -> [AtomicUnit] {
        units.values.filter { $0.status == .active }
    }

    /// Returns all invalidated units.
    func invalidatedUnits() -> [AtomicUnit] {
        units.values.filter { $0.status == .invalidated }
    }

    /// Returns all units regardless of status.
    func allUnits() -> [AtomicUnit] {
        Array(units.values)
    }

    /// Returns the active unit for a supersession key, if any.
    func activeUnit(for key: SupersessionKey) -> AtomicUnit? {
        guard let id = activeByKey[key] else { return nil }
        return units[id]
    }

    /// Returns all unit identifiers currently in the store.
    var allUnitIds: Set<UnitIdentifier> {
        Set(units.keys)
    }

    /// Total unit count.
    var count: Int { units.count }

    /// Count of active units.
    var activeCount: Int { activeByKey.count }

    // MARK: — Write Transaction (PC-6)

    /// Processes a write transaction atomically.
    ///
    /// DDS-002 PC-6: All operations succeed or none are applied.
    /// Admissions are processed before status transitions.
    /// Units admitted earlier in the transaction are visible to later validations.
    ///
    /// Returns the committed transaction result, or a rejection with diagnostics.
    mutating func processTransaction(
        _ transaction: WriteTransaction
    ) -> WriteTransactionResult {
        // Phase 1: Validate all admissions
        var batchAdmittedIds = Set<UnitIdentifier>()
        let admissionFailures = IntakeValidator.validateBatch(
            transaction.admissions,
            existingUnitIds: allUnitIds,
            batchAdmittedIds: &batchAdmittedIds,
            nextId: nextUnitId
        )

        // Phase 2: Validate all transitions
        let transitionFailures = IntakeValidator.validateTransitions(
            transaction.transitions
        ) { id in
            self.unit(for: id)
        }

        let allFailures = admissionFailures + transitionFailures
        if !allFailures.isEmpty {
            return .rejected(TransactionRejection(failures: allFailures))
        }

        // Phase 3: Apply admissions (all validated, now commit)
        var admittedUnitIds: [UnitIdentifier] = []
        var supersededUnitIds: [UnitIdentifier] = []

        for admission in transaction.admissions {
            let id = assignId()
            let unit = AtomicUnit(
                id: id,
                subject: admission.subject,
                predicate: admission.predicate,
                value: admission.value,
                tier: admission.tier,
                provenance: admission.provenance,
                confidence: admission.confidence,
                grounding: admission.grounding,
                version: admission.version
            )

            // Check for supersession
            let key = unit.supersessionKey
            if let existingId = activeByKey[key] {
                // Supersede existing unit
                if var existingUnit = units[existingId] {
                    existingUnit.supersede(by: id)
                    units[existingId] = existingUnit
                    supersededUnitIds.append(existingId)
                }
            }

            // Insert new unit as Active
            units[id] = unit
            activeByKey[key] = id
            admittedUnitIds.append(id)
        }

        // Phase 4: Apply status transitions
        for transition in transaction.transitions {
            guard var unit = units[transition.unitId] else { continue }

            switch transition.targetStatus {
            case .invalidated:
                if let metadata = transition.invalidationMetadata {
                    unit.invalidate(metadata: metadata)
                }
            case .superseded:
                if let successor = transition.supersededBy {
                    unit.supersede(by: successor)
                }
            case .garbageCollected:
                unit.garbageCollect()
            case .active:
                break // Invalid — would have been caught in validation
            }

            units[transition.unitId] = unit

            // Update active index
            if transition.targetStatus != .active {
                let key = unit.supersessionKey
                if activeByKey[key] == transition.unitId {
                    activeByKey.removeValue(forKey: key)
                }
            }
        }

        return .committed(CommittedTransaction(
            epoch: .zero, // Caller sets the actual epoch
            admittedUnitIds: admittedUnitIds,
            supersededUnitIds: supersededUnitIds,
            appliedTransitions: transaction.transitions
        ))
    }

    // MARK: — Snapshot Loading

    /// Populates the store from snapshot data.
    ///
    /// Used during startup to restore DIR state from a persisted snapshot.
    mutating func loadFromSnapshot(_ snapshot: SnapshotData) {
        units.removeAll()
        activeByKey.removeAll()

        for unit in snapshot.units {
            units[unit.id] = unit
            if unit.status == .active {
                activeByKey[unit.supersessionKey] = unit.id
            }
        }

        nextUnitId = snapshot.nextUnitId
    }

    /// Clears all state.
    mutating func clear() {
        units.removeAll()
        activeByKey.removeAll()
    }
}
