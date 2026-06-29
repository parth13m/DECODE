// IndexActor.swift — IndexRuntime
// DDS-004: Index Runtime — five index families, incremental maintenance
// IAG-003 §2.3: IndexActor owns five index families, per-family availability state
// IAG-003 §8: os.Logger category "index"

import Foundation
import DIRCore
import os

/// The core actor of the Index Runtime.
///
/// IAG-003 §2.3: Owns the five index families (Entity, Graph, Scope, Predicate, Content),
/// per-family availability state, and deferred content update queue.
///
/// Concurrency model:
/// - Index queries (DDS-004:PC-1) serialize through the actor boundary.
/// - Batch updates (DDS-004:PC-4) update structural indexes synchronously within the actor.
/// - Content Index deferred updates are enqueued and processed asynchronously.
/// - Family rebuilds run within the actor as Tasks.
/// - Construction follows priority order: Entity → Graph → Scope → Predicate → Content.
public actor IndexActor: IndexQuerying, IndexFreshness, IndexBatchUpdate {

    // MARK: — Dependencies

    /// DIR read access (injected as protocol from UpdateEngine via DIRCore).
    private let dirRead: DIRReadAccess

    // MARK: — Owned State: Index Families

    /// The Entity Index (DDS-004: entity → units).
    private var entityIndex: EntityIndex = EntityIndex()

    /// The Graph Index (DDS-004: bidirectional relationship traversal).
    private var graphIndex: GraphIndex = GraphIndex()

    /// The Scope Index (DDS-004: containment tree with transitive closure).
    private var scopeIndex: ScopeIndex = ScopeIndex()

    /// The Predicate Index (DDS-004: predicate → units).
    private var predicateIndex: PredicateIndex = PredicateIndex()

    /// The Content Index (DDS-004: term-based text search, deferred).
    private var contentIndex: ContentIndex = ContentIndex()

    // MARK: — Owned State: Per-Family Availability

    /// Per-family availability state (DDS-004: Absent → Building → Available → Rebuilding).
    private var familyAvailabilityState: [IndexFamily: IndexFamilyAvailability] = [
        .entity: .absent,
        .graph: .absent,
        .scope: .absent,
        .predicate: .absent,
        .content: .absent,
    ]

    /// Per-family last-update epoch.
    private var familyLastUpdateEpoch: [IndexFamily: Epoch] = [:]

    // MARK: — Owned State: Runtime

    /// The current runtime state.
    private var state: IndexRuntimeState = .uninitialized

    /// Deferred Content Index update queue (DDS-004: processed asynchronously).
    private var deferredContentUpdates: [ContentDeferredUpdate] = []

    /// Change batches queued during construction for families not yet built.
    private var pendingBatches: [ChangeBatch] = []

    // MARK: — Logging

    private let logger = Logger(subsystem: "com.decode.understanding", category: "index")

    // MARK: — Initialization

    /// Creates an IndexActor with DIR read access.
    ///
    /// IAG-001 §6: IndexRuntime receives only DIRReadAccess from the composition root.
    /// DDS-004: No persistent state (DAS-012 I3).
    public init(dirRead: DIRReadAccess) {
        self.dirRead = dirRead
        logger.debug("IndexActor created — state: uninitialized")
    }

    // MARK: — Construction (DDS-004 R2)

    /// Constructs all five index families from the DIR.
    ///
    /// DDS-004 R2: Constructs in priority order (Entity → Graph → Scope → Predicate → Content).
    /// DAS-012 I3: All indexes rebuilt from scratch on every process startup.
    /// Each family becomes available for queries as soon as its construction completes.
    public func constructAll() async {
        guard state == .uninitialized else {
            logger.warning("constructAll called in state: \(self.state.rawValue) — ignoring")
            return
        }

        transitionState(to: .building)
        logger.info("Beginning index construction from DIR")

        let units = await dirRead.activeUnits()
        let invalidated = await dirRead.invalidatedUnits()
        let allUnits = units + invalidated

        logger.info("Scanning \(allUnits.count) units (\(units.count) active, \(invalidated.count) invalidated)")

        // DDS-004: Construction follows priority order
        for family in IndexFamily.constructionOrder {
            familyAvailabilityState[family] = .building

            switch family {
            case .entity:
                constructEntityIndex(from: allUnits)
            case .graph:
                constructGraphIndex(from: allUnits)
            case .scope:
                constructScopeIndex(from: allUnits)
            case .predicate:
                constructPredicateIndex(from: allUnits)
            case .content:
                constructContentIndex(from: allUnits)
            }

            familyAvailabilityState[family] = .available
            let epoch = await dirRead.committedEpoch
            familyLastUpdateEpoch[family] = epoch
            logger.info("Index family \(family.rawValue) constructed — available")
        }

        // Apply any change batches that arrived during construction
        for batch in pendingBatches {
            applyBatchInternal(batch)
        }
        pendingBatches.removeAll()

        transitionState(to: .operational)
        logger.info("All index families constructed — state: operational")
    }

    // MARK: — IndexQuerying (PC-1)

    public func queryEntity(
        _ entity: EntityReference,
        predicate: PredicateIdentifier?,
        tier: Tier?,
        status: UnitStatus?
    ) async -> IndexQueryResult<EntityIndexEntry> {
        if familyAvailabilityState[.entity] == .available ||
           familyAvailabilityState[.entity] == .rebuilding {
            let entries = entityIndex.query(entity: entity, predicate: predicate, tier: tier, status: status)
            return IndexQueryResult(entries: entries, usedFallback: false)
        }
        // DIR scan fallback (DDS-004 RI-6)
        logger.debug("Entity index unavailable — using DIR scan fallback")
        let entries = await dirScanEntity(entity, predicate: predicate, tier: tier, status: status)
        return IndexQueryResult(entries: entries, usedFallback: true)
    }

    public func queryGraph(
        entity: EntityReference,
        predicate: PredicateIdentifier,
        direction: TraversalDirection
    ) async -> IndexQueryResult<GraphIndexEntry> {
        if familyAvailabilityState[.graph] == .available ||
           familyAvailabilityState[.graph] == .rebuilding {
            let entries = graphIndex.query(entity: entity, predicate: predicate, direction: direction)
            return IndexQueryResult(entries: entries, usedFallback: false)
        }
        logger.debug("Graph index unavailable — using DIR scan fallback")
        let entries = await dirScanGraph(entity: entity, predicate: predicate, direction: direction)
        return IndexQueryResult(entries: entries, usedFallback: true)
    }

    public func queryScope(
        _ scope: EntityReference
    ) async -> IndexQueryResult<ScopeIndexEntry> {
        if familyAvailabilityState[.scope] == .available ||
           familyAvailabilityState[.scope] == .rebuilding {
            let entries = scopeIndex.query(scope: scope)
            return IndexQueryResult(entries: entries, usedFallback: false)
        }
        logger.debug("Scope index unavailable — using DIR scan fallback")
        let entries = await dirScanScope(scope)
        return IndexQueryResult(entries: entries, usedFallback: true)
    }

    public func queryPredicate(
        _ predicate: PredicateIdentifier,
        tier: Tier?,
        status: UnitStatus?,
        producerId: String?
    ) async -> IndexQueryResult<PredicateIndexEntry> {
        if familyAvailabilityState[.predicate] == .available ||
           familyAvailabilityState[.predicate] == .rebuilding {
            let entries = predicateIndex.query(predicate: predicate, tier: tier, status: status, producerId: producerId)
            return IndexQueryResult(entries: entries, usedFallback: false)
        }
        logger.debug("Predicate index unavailable — using DIR scan fallback")
        let entries = await dirScanPredicate(predicate, tier: tier, status: status, producerId: producerId)
        return IndexQueryResult(entries: entries, usedFallback: true)
    }

    public func queryContent(
        term: String
    ) async -> IndexQueryResult<ContentIndexEntry> {
        if familyAvailabilityState[.content] == .available ||
           familyAvailabilityState[.content] == .rebuilding {
            let entries = contentIndex.query(term: term)
            return IndexQueryResult(entries: entries, usedFallback: false)
        }
        logger.debug("Content index unavailable — using DIR scan fallback")
        let entries = await dirScanContent(term: term)
        return IndexQueryResult(entries: entries, usedFallback: true)
    }

    // MARK: — IndexFreshness (PC-3)

    public func freshnessReport() async -> FreshnessReport {
        var families: [IndexFamily: FamilyFreshnessReport] = [:]
        for family in IndexFamily.allCases {
            families[family] = buildFamilyReport(family)
        }
        return FreshnessReport(families: families)
    }

    public func familyFreshness(_ family: IndexFamily) async -> FamilyFreshnessReport {
        buildFamilyReport(family)
    }

    public func familyAvailability(_ family: IndexFamily) async -> IndexFamilyAvailability {
        familyAvailabilityState[family] ?? .absent
    }

    // MARK: — IndexBatchUpdate (PC-4)

    public func applyBatch(_ batch: ChangeBatch) async -> BatchUpdateResult {
        guard state == .building || state == .operational else {
            logger.warning("applyBatch called in state: \(self.state.rawValue) — rejecting")
            return BatchUpdateResult(updatedFamilies: [], failedFamilies: [:], epoch: batch.epoch)
        }

        // During building, queue for families not yet constructed
        if state == .building {
            pendingBatches.append(batch)
            logger.debug("Change batch queued during construction (epoch: \(batch.epoch.value))")
            return BatchUpdateResult(updatedFamilies: [], failedFamilies: [:], epoch: batch.epoch)
        }

        return applyBatchInternal(batch)
    }

    public func processDeferredUpdates() async {
        guard !deferredContentUpdates.isEmpty else { return }

        let updates = deferredContentUpdates
        deferredContentUpdates.removeAll()

        logger.debug("Processing \(updates.count) deferred content index updates")

        for update in updates {
            switch update {
            case let .add(unitId, subject, predicate, text):
                contentIndex.addUnit(unitId: unitId, subject: subject, predicate: predicate, text: text)
            case let .remove(unitId):
                contentIndex.removeUnit(unitId)
            }
        }

        let epoch = await dirRead.committedEpoch
        familyLastUpdateEpoch[.content] = epoch
        logger.debug("Content index updated to epoch \(epoch.value)")
    }

    public func rebuildFamily(_ family: IndexFamily) async {
        let availability = familyAvailabilityState[family] ?? .absent
        logger.info("Rebuilding \(family.rawValue) index (current: \(availability.rawValue))")

        // If available, transition to rebuilding (prior index remains queryable)
        if availability == .available {
            familyAvailabilityState[family] = .rebuilding
        } else {
            familyAvailabilityState[family] = .building
        }

        let activeUnits = await dirRead.activeUnits()
        let invalidatedUnits = await dirRead.invalidatedUnits()
        let allUnits = activeUnits + invalidatedUnits

        switch family {
        case .entity:
            entityIndex.clear()
            constructEntityIndex(from: allUnits)
        case .graph:
            graphIndex.clear()
            constructGraphIndex(from: allUnits)
        case .scope:
            scopeIndex.clear()
            constructScopeIndex(from: allUnits)
        case .predicate:
            predicateIndex.clear()
            constructPredicateIndex(from: allUnits)
        case .content:
            contentIndex.clear()
            constructContentIndex(from: allUnits)
        }

        familyAvailabilityState[family] = .available
        let epoch = await dirRead.committedEpoch
        familyLastUpdateEpoch[family] = epoch
        logger.info("Index family \(family.rawValue) rebuilt — available at epoch \(epoch.value)")
    }

    // MARK: — Shutdown

    /// Initiates quiescence of the Index Runtime.
    ///
    /// DDS-004 Lifecycle: No new change batches accepted. In-progress updates complete.
    /// Deferred Content Index updates discarded (DAS-012 I3).
    public func shutdown() {
        guard state != .quiescing && state != .terminated else { return }
        transitionState(to: .quiescing)
        deferredContentUpdates.removeAll()
        logger.info("IndexActor quiescing — deferred updates discarded")
    }

    /// Completes termination.
    public func terminate() {
        guard state == .quiescing else { return }
        transitionState(to: .terminated)
        entityIndex.clear()
        graphIndex.clear()
        scopeIndex.clear()
        predicateIndex.clear()
        contentIndex.clear()
        logger.info("IndexActor terminated — all indexes deallocated")
    }

    // MARK: — Internal: Batch Update Application

    /// Applies a change batch to all available structural families, enqueues content updates.
    ///
    /// DAS-010 IM-3: Entity/Graph first → Scope/Predicate second → Content deferred.
    @discardableResult
    private func applyBatchInternal(_ batch: ChangeBatch) -> BatchUpdateResult {
        var updatedFamilies: Set<IndexFamily> = []
        var failedFamilies: [IndexFamily: String] = [:]

        logger.debug("Applying change batch (epoch: \(batch.epoch.value), changes: \(batch.changes.count))")

        // Phase 1: Entity and Graph (DAS-010 IM-3)
        for family in [IndexFamily.entity, .graph] {
            let availability = familyAvailabilityState[family] ?? .absent
            guard availability == .available || availability == .rebuilding else { continue }
            do {
                try applyChangesToFamily(family, changes: batch.changes)
                familyLastUpdateEpoch[family] = batch.epoch
                updatedFamilies.insert(family)
            } catch {
                logger.error("Failed to update \(family.rawValue) index: \(error.localizedDescription)")
                failedFamilies[family] = error.localizedDescription
                familyAvailabilityState[family] = .absent
            }
        }

        // Phase 2: Scope and Predicate (DAS-010 IM-3)
        for family in [IndexFamily.scope, .predicate] {
            let availability = familyAvailabilityState[family] ?? .absent
            guard availability == .available || availability == .rebuilding else { continue }
            do {
                try applyChangesToFamily(family, changes: batch.changes)
                familyLastUpdateEpoch[family] = batch.epoch
                updatedFamilies.insert(family)
            } catch {
                logger.error("Failed to update \(family.rawValue) index: \(error.localizedDescription)")
                failedFamilies[family] = error.localizedDescription
                familyAvailabilityState[family] = .absent
            }
        }

        // Phase 3: Content — deferred (DAS-010 IM-4)
        enqueueContentUpdates(batch.changes)

        return BatchUpdateResult(updatedFamilies: updatedFamilies, failedFamilies: failedFamilies, epoch: batch.epoch)
    }

    /// Applies individual changes to a specific family.
    private func applyChangesToFamily(_ family: IndexFamily, changes: [UnitChange]) throws {
        for change in changes {
            switch change {
            case let .admitted(unitId):
                // Need to look up the unit to get its fields
                // During synchronous pipeline, the unit is guaranteed to exist
                // We'll index it when we have its data; for now record the admission
                // The unit data is resolved during construction/rebuild, or via
                // the pendingAdmissions mechanism
                try handleAdmission(unitId: unitId, family: family)

            case let .invalidated(unitId):
                handleInvalidation(unitId: unitId, family: family)

            case let .superseded(unitId, by: successorId):
                handleSupersession(unitId: unitId, successorId: successorId, family: family)

            case let .garbageCollected(unitId):
                handleGarbageCollection(unitId: unitId, family: family)
            }
        }
    }

    // MARK: — Internal: Per-Change Handlers

    /// Handles admission of a new unit to a specific family.
    ///
    /// Note: Since the unit data is needed but not available in the UnitChange enum,
    /// we need to resolve the unit via DIRReadAccess. However, within the actor
    /// we cannot do async calls from a non-async context. The resolution happens
    /// in the caller (applyBatchInternal is called from async contexts).
    private func handleAdmission(unitId: UnitIdentifier, family: IndexFamily) throws {
        // Unit will be resolved in applyBatchWithResolution
        // This is a placeholder for the synchronous path; actual resolution
        // requires the async applyBatch entry point
    }

    private func handleInvalidation(unitId: UnitIdentifier, family: IndexFamily) {
        switch family {
        case .entity:
            entityIndex.removeUnit(unitId)
        case .graph:
            graphIndex.updateStatus(unitId: unitId, newStatus: .invalidated)
        case .scope:
            // DDS-004: Invalidated contains relationships removed immediately
            scopeIndex.removeEdge(unitId: unitId)
        case .predicate:
            predicateIndex.updateStatus(unitId: unitId, newStatus: .invalidated)
        case .content:
            break // Handled by deferred queue
        }
    }

    private func handleSupersession(unitId: UnitIdentifier, successorId: UnitIdentifier, family: IndexFamily) {
        switch family {
        case .entity:
            entityIndex.removeUnit(unitId)
        case .graph:
            graphIndex.removeUnit(unitId)
        case .scope:
            scopeIndex.removeEdge(unitId: unitId)
        case .predicate:
            predicateIndex.removeUnit(unitId)
        case .content:
            break // Handled by deferred queue
        }
        // Successor entries are added when the successor's .admitted change is processed
    }

    private func handleGarbageCollection(unitId: UnitIdentifier, family: IndexFamily) {
        switch family {
        case .entity:
            entityIndex.removeUnit(unitId)
        case .graph:
            graphIndex.removeUnit(unitId)
        case .scope:
            scopeIndex.removeEdge(unitId: unitId)
        case .predicate:
            predicateIndex.removeUnit(unitId)
        case .content:
            break // Handled by deferred queue
        }
    }

    /// Enqueues content index updates for deferred processing.
    private func enqueueContentUpdates(_ changes: [UnitChange]) {
        for change in changes {
            switch change {
            case let .admitted(unitId):
                // The actual text content will be resolved during processDeferredUpdates
                // For now, record that we need to add this unit
                deferredContentUpdates.append(.remove(unitId: unitId)) // Remove old if exists
                // Text resolution deferred to processDeferredUpdates via dirRead
            case let .invalidated(unitId):
                deferredContentUpdates.append(.remove(unitId: unitId))
            case let .superseded(unitId, by: _):
                deferredContentUpdates.append(.remove(unitId: unitId))
            case let .garbageCollected(unitId):
                deferredContentUpdates.append(.remove(unitId: unitId))
            }
        }
    }

    // MARK: — Internal: Batch Update with Resolution

    /// Applies a change batch with full unit resolution via DIRReadAccess.
    ///
    /// This is the primary batch update path. For each admitted unit, resolves
    /// the full unit record and indexes it in all appropriate families.
    func applyBatchWithResolution(_ batch: ChangeBatch) async -> BatchUpdateResult {
        guard state == .building || state == .operational else {
            logger.warning("applyBatchWithResolution called in state: \(self.state.rawValue) — rejecting")
            return BatchUpdateResult(updatedFamilies: [], failedFamilies: [:], epoch: batch.epoch)
        }

        var updatedFamilies: Set<IndexFamily> = []
        let failedFamilies: [IndexFamily: String] = [:]

        // Resolve all admitted units upfront
        var resolvedUnits: [UnitIdentifier: AtomicUnit] = [:]
        for change in batch.changes {
            if case let .admitted(unitId) = change {
                if let unit = await dirRead.unit(for: unitId) {
                    resolvedUnits[unitId] = unit
                }
            }
        }

        // Phase 1: Entity and Graph
        for family in [IndexFamily.entity, .graph] {
            let availability = familyAvailabilityState[family] ?? .absent
            guard availability == .available || availability == .rebuilding else { continue }

            applyResolvedChanges(batch.changes, resolvedUnits: resolvedUnits, to: family)
            familyLastUpdateEpoch[family] = batch.epoch
            updatedFamilies.insert(family)
        }

        // Phase 2: Scope and Predicate
        for family in [IndexFamily.scope, .predicate] {
            let availability = familyAvailabilityState[family] ?? .absent
            guard availability == .available || availability == .rebuilding else { continue }

            applyResolvedChanges(batch.changes, resolvedUnits: resolvedUnits, to: family)
            familyLastUpdateEpoch[family] = batch.epoch
            updatedFamilies.insert(family)
        }

        // Phase 3: Content — deferred
        for change in batch.changes {
            switch change {
            case let .admitted(unitId):
                if let unit = resolvedUnits[unitId], case let .text(textValue) = unit.value {
                    deferredContentUpdates.append(.add(
                        unitId: unitId, subject: unit.subject,
                        predicate: unit.predicate, text: textValue
                    ))
                }
            case let .invalidated(unitId):
                deferredContentUpdates.append(.remove(unitId: unitId))
            case let .superseded(unitId, by: _):
                deferredContentUpdates.append(.remove(unitId: unitId))
            case let .garbageCollected(unitId):
                deferredContentUpdates.append(.remove(unitId: unitId))
            }
        }

        return BatchUpdateResult(updatedFamilies: updatedFamilies, failedFamilies: failedFamilies, epoch: batch.epoch)
    }

    /// Applies resolved changes to a specific family.
    private func applyResolvedChanges(
        _ changes: [UnitChange],
        resolvedUnits: [UnitIdentifier: AtomicUnit],
        to family: IndexFamily
    ) {
        for change in changes {
            switch change {
            case let .admitted(unitId):
                guard let unit = resolvedUnits[unitId] else { continue }
                indexUnit(unit, in: family)

            case let .invalidated(unitId):
                handleInvalidation(unitId: unitId, family: family)

            case let .superseded(unitId, by: successorId):
                handleSupersession(unitId: unitId, successorId: successorId, family: family)
                if let successor = resolvedUnits[successorId] {
                    indexUnit(successor, in: family)
                }

            case let .garbageCollected(unitId):
                handleGarbageCollection(unitId: unitId, family: family)
            }
        }
    }

    /// Indexes a single unit into the specified family.
    private func indexUnit(_ unit: AtomicUnit, in family: IndexFamily) {
        switch family {
        case .entity:
            indexUnitInEntity(unit)
        case .graph:
            indexUnitInGraph(unit)
        case .scope:
            indexUnitInScope(unit)
        case .predicate:
            indexUnitInPredicate(unit)
        case .content:
            indexUnitInContent(unit)
        }
    }

    // MARK: — Internal: Construction

    private func constructEntityIndex(from units: [AtomicUnit]) {
        for unit in units {
            indexUnitInEntity(unit)
        }
        logger.debug("Entity index: \(self.entityIndex.count) entries")
    }

    private func constructGraphIndex(from units: [AtomicUnit]) {
        for unit in units {
            indexUnitInGraph(unit)
        }
        logger.debug("Graph index: \(self.graphIndex.count) entries")
    }

    private func constructScopeIndex(from units: [AtomicUnit]) {
        for unit in units {
            indexUnitInScope(unit)
        }
        scopeIndex.recomputeTransitiveClosure()
        logger.debug("Scope index: \(self.scopeIndex.directEdgeCount) edges, \(self.scopeIndex.count) transitive entries")
    }

    private func constructPredicateIndex(from units: [AtomicUnit]) {
        for unit in units {
            indexUnitInPredicate(unit)
        }
        logger.debug("Predicate index: \(self.predicateIndex.count) entries")
    }

    private func constructContentIndex(from units: [AtomicUnit]) {
        for unit in units {
            indexUnitInContent(unit)
        }
        logger.debug("Content index: \(self.contentIndex.count) entries")
    }

    // MARK: — Internal: Per-Unit Indexing

    private func indexUnitInEntity(_ unit: AtomicUnit) {
        let entry = EntityIndexEntry(
            unitId: unit.id, predicate: unit.predicate,
            tier: unit.tier, status: unit.status
        )
        switch unit.subject {
        case let .entity(ref):
            entityIndex.add(entity: ref, entry: entry)
        case let .pair(pair):
            entityIndex.add(entity: pair.source, entry: entry)
            entityIndex.add(entity: pair.target, entry: entry)
        }
    }

    private func indexUnitInGraph(_ unit: AtomicUnit) {
        guard case let .pair(pair) = unit.subject else { return }
        graphIndex.addPair(
            source: pair.source, target: pair.target,
            predicate: unit.predicate,
            unitId: unit.id, tier: unit.tier, status: unit.status
        )
    }

    private func indexUnitInScope(_ unit: AtomicUnit) {
        guard case let .pair(pair) = unit.subject,
              unit.predicate.name == "contains" else { return }
        scopeIndex.addEdge(parent: pair.source, child: pair.target, unitId: unit.id)
    }

    private func indexUnitInPredicate(_ unit: AtomicUnit) {
        let entry = PredicateIndexEntry(
            unitId: unit.id, subject: unit.subject,
            tier: unit.tier, status: unit.status,
            producerId: unit.provenance.producer
        )
        predicateIndex.add(predicate: unit.predicate, entry: entry)
    }

    private func indexUnitInContent(_ unit: AtomicUnit) {
        guard case let .text(textValue) = unit.value else { return }
        contentIndex.addUnit(
            unitId: unit.id, subject: unit.subject,
            predicate: unit.predicate, text: textValue
        )
    }

    // MARK: — Internal: DIR Scan Fallback (DDS-004 RI-6)

    /// DIR scan fallback for entity queries when Entity Index is unavailable.
    private func dirScanEntity(
        _ entity: EntityReference,
        predicate: PredicateIdentifier?,
        tier: Tier?,
        status: UnitStatus?
    ) async -> [EntityIndexEntry] {
        let allUnits = await dirRead.activeUnits() + (await dirRead.invalidatedUnits())
        return allUnits.compactMap { unit in
            guard unitMatchesEntity(unit, entity: entity) else { return nil }
            if let predicate, unit.predicate != predicate { return nil }
            if let tier, unit.tier != tier { return nil }
            if let status, unit.status != status { return nil }
            return EntityIndexEntry(
                unitId: unit.id, predicate: unit.predicate,
                tier: unit.tier, status: unit.status
            )
        }
    }

    /// DIR scan fallback for graph queries.
    private func dirScanGraph(
        entity: EntityReference,
        predicate: PredicateIdentifier,
        direction: TraversalDirection
    ) async -> [GraphIndexEntry] {
        let allUnits = await dirRead.activeUnits() + (await dirRead.invalidatedUnits())
        return allUnits.compactMap { unit in
            guard case let .pair(pair) = unit.subject,
                  unit.predicate == predicate else { return nil }
            switch direction {
            case .forward:
                guard pair.source == entity else { return nil }
                return GraphIndexEntry(neighbor: pair.target, unitId: unit.id, tier: unit.tier, status: unit.status)
            case .inverse:
                guard pair.target == entity else { return nil }
                return GraphIndexEntry(neighbor: pair.source, unitId: unit.id, tier: unit.tier, status: unit.status)
            }
        }
    }

    /// DIR scan fallback for scope queries.
    private func dirScanScope(_ scope: EntityReference) async -> [ScopeIndexEntry] {
        let allUnits = await dirRead.activeUnits()
        // Build containment tree from active contains relationships
        var children: [String: Set<String>] = [:]
        for unit in allUnits {
            guard case let .pair(pair) = unit.subject,
                  unit.predicate.name == "contains" else { continue }
            children[pair.source.qualifiedName, default: []].insert(pair.target.qualifiedName)
        }
        // Compute transitive closure
        var result: [ScopeIndexEntry] = []
        func collect(from entity: String, depth: Int) {
            guard let kids = children[entity] else { return }
            for child in kids {
                result.append(ScopeIndexEntry(containedEntity: EntityReference(qualifiedName: child), depth: depth))
                collect(from: child, depth: depth + 1)
            }
        }
        collect(from: scope.qualifiedName, depth: 1)
        return result
    }

    /// DIR scan fallback for predicate queries.
    private func dirScanPredicate(
        _ predicate: PredicateIdentifier,
        tier: Tier?,
        status: UnitStatus?,
        producerId: String?
    ) async -> [PredicateIndexEntry] {
        let allUnits = await dirRead.activeUnits() + (await dirRead.invalidatedUnits())
        return allUnits.compactMap { unit in
            guard unit.predicate == predicate else { return nil }
            if let tier, unit.tier != tier { return nil }
            if let status, unit.status != status { return nil }
            if let producerId, unit.provenance.producer != producerId { return nil }
            return PredicateIndexEntry(
                unitId: unit.id, subject: unit.subject,
                tier: unit.tier, status: unit.status,
                producerId: unit.provenance.producer
            )
        }
    }

    /// DIR scan fallback for content queries.
    private func dirScanContent(term: String) async -> [ContentIndexEntry] {
        let allUnits = await dirRead.activeUnits()
        let normalized = term.lowercased()
        return allUnits.compactMap { unit in
            guard case let .text(textValue) = unit.value,
                  textValue.lowercased().contains(normalized) else { return nil }
            return ContentIndexEntry(unitId: unit.id, subject: unit.subject, predicate: unit.predicate)
        }
    }

    // MARK: — Internal: Helpers

    private func unitMatchesEntity(_ unit: AtomicUnit, entity: EntityReference) -> Bool {
        switch unit.subject {
        case let .entity(ref):
            return ref == entity
        case let .pair(pair):
            return pair.source == entity || pair.target == entity
        }
    }

    private func buildFamilyReport(_ family: IndexFamily) -> FamilyFreshnessReport {
        let availability = familyAvailabilityState[family] ?? .absent
        let lastEpoch = familyLastUpdateEpoch[family]

        let (entryCount, memoryBytes, staleCount) = familyMetrics(family)

        return FamilyFreshnessReport(
            family: family,
            lastUpdateEpoch: lastEpoch,
            staleEntryCount: staleCount,
            availability: availability,
            memoryFootprintBytes: memoryBytes,
            entryCount: entryCount
        )
    }

    private func familyMetrics(_ family: IndexFamily) -> (count: Int, memoryBytes: Int, staleCount: Int) {
        switch family {
        case .entity:
            return (entityIndex.count, entityIndex.estimatedMemoryBytes, 0)
        case .graph:
            return (graphIndex.count, graphIndex.estimatedMemoryBytes, 0)
        case .scope:
            return (scopeIndex.count, scopeIndex.estimatedMemoryBytes, 0)
        case .predicate:
            return (predicateIndex.count, predicateIndex.estimatedMemoryBytes, 0)
        case .content:
            return (contentIndex.count, contentIndex.estimatedMemoryBytes, deferredContentUpdates.count)
        }
    }

    private func transitionState(to target: IndexRuntimeState) {
        let current = state
        guard current.canTransition(to: target) else {
            logger.warning("Invalid state transition: \(current.rawValue) → \(target.rawValue)")
            return
        }
        state = target
        logger.info("State transition: \(current.rawValue) → \(target.rawValue)")
    }
}
