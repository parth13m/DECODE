// ModuleObservationTests.swift — DecodeTests
// M6: Tests for module observation extraction, suppression, interpretation,
// guidance generation, prompt injection, and reasoning engine integration.

import Testing
import Foundation
@testable import Decode
import ConsumerRuntime
import ContextAssembly
import RetrievalRuntime
import DIRCore

// MARK: - Test Helpers

private let testHash = ContentHash(bytes: Array(repeating: 0, count: 32))

/// Creates a test AtomicUnit for an entity.
private func makeUnit(
    id: UInt64,
    entityName: String,
    predicateName: String,
    predicateDomain: String = "structure",
    value: TypedValue,
    tier: Tier = .t0
) -> AtomicUnit {
    AtomicUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .entity(EntityReference(qualifiedName: entityName)),
        predicate: PredicateIdentifier(name: predicateName, domain: predicateDomain),
        value: value,
        tier: tier,
        provenance: ProvenanceRecord(
            producer: "test-producer",
            method: .extraction,
            timestamp: Date(timeIntervalSince1970: 0)
        ),
        confidence: tier == .t0 ? .deterministic : .high,
        grounding: .direct(SourcePosition(
            filePath: "test.swift",
            startLine: 1,
            endLine: 10,
            fileVersion: testHash
        )),
        version: VersionStamp(singleSource: testHash)
    )
}

/// Creates a relationship unit.
private func makeRelUnit(
    id: UInt64,
    source: String,
    predicate: String,
    target: String,
    tier: Tier = .t0
) -> AtomicUnit {
    AtomicUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .pair(EntityPair(
            source: EntityReference(qualifiedName: source),
            target: EntityReference(qualifiedName: target)
        )),
        predicate: PredicateIdentifier(name: predicate, domain: "relationship"),
        value: .boolean(true),
        tier: tier,
        provenance: ProvenanceRecord(
            producer: "test-producer",
            method: .extraction,
            timestamp: Date(timeIntervalSince1970: 0)
        ),
        confidence: tier == .t0 ? .deterministic : .high,
        grounding: .direct(SourcePosition(
            filePath: "test.swift",
            startLine: 1,
            endLine: 5,
            fileVersion: testHash
        )),
        version: VersionStamp(singleSource: testHash)
    )
}

/// Creates a ContextUnit from an AtomicUnit.
private func contextUnit(from unit: AtomicUnit) -> ContextUnit {
    ContextUnit(
        annotatedUnit: AnnotatedUnit(
            unit: unit,
            provenance: EvidenceProvenance(stage: .scope, path: ["scope"]),
            distance: 2
        ),
        role: ContextRole(stratumName: "module", reason: "test")
    )
}

/// Creates a ContextFrame from units.
private func makeFrame(units: [AtomicUnit]) -> ContextFrame {
    let contextUnits = units.map { contextUnit(from: $0) }
    let stratum = FilledStratum(
        name: "primary",
        priority: 0,
        units: contextUnits,
        budgetAllocated: 1000,
        budgetUsed: units.count
    )
    let tierCounts: [Tier: Int] = Dictionary(
        units.map { ($0.tier, 1) },
        uniquingKeysWith: +
    )
    return ContextFrame(
        anchors: units.compactMap { unit in
            if case .entity(let ref) = unit.subject { return ref }
            return nil
        },
        purpose: ContextPurpose("explain"),
        strategyVersion: "test-2.0",
        strata: [stratum],
        budgetSummary: BudgetSummary(total: 1000, denomination: .unitCount, used: units.count),
        metadata: ContextFrameMetadata(
            evidenceSetSize: units.count,
            selectedCount: units.count,
            tierCounts: tierCounts,
            stratumCounts: ["primary": units.count],
            coherenceStatistics: CoherenceStatistics(fired: 0, satisfied: 0, retracted: 0),
            degradationLevel: .full,
            freshnessState: .fresh,
            assemblyDuration: 0.001,
            strategyVersion: "test-2.0",
            committedEpoch: Epoch(value: 1),
            budgetInsufficient: false
        )
    )
}

/// Helper to build standard module units for a provider module with common properties.
private func makeProviderModuleUnits(
    moduleName: String = "Application",
    fileCount: Int = 5,
    cohesionRatio: Double = 0.85,
    cohesionInternal: Int = 45,
    cohesionExternal: Int = 8,
    publicEntities: String = "SessionResolver, WorkspaceResolver",
    publicCount: Int = 2,
    interactionCalls: Int = 30,
    interactionConformsTo: Int = 5,
    interactionInherits: Int = 2,
    inboundCalls: Int = 15,
    outboundCalls: Int = 3,
    startId: UInt64 = 100
) -> [AtomicUnit] {
    let moduleEntity = "module:\(moduleName)"
    return [
        makeUnit(id: startId, entityName: moduleEntity, predicateName: "kind",
                 predicateDomain: "structure", value: .string("module"), tier: .t1),
        makeUnit(id: startId + 1, entityName: moduleEntity, predicateName: "fileCount",
                 predicateDomain: "composition", value: .integer(Int64(fileCount)), tier: .t1),
        makeUnit(id: startId + 2, entityName: moduleEntity, predicateName: "moduleRole",
                 predicateDomain: "emergence", value: .string("provider"), tier: .t1),
        makeUnit(id: startId + 3, entityName: moduleEntity, predicateName: "cohesion",
                 predicateDomain: "emergence",
                 value: .structured([
                    "internal": .integer(Int64(cohesionInternal)),
                    "external": .integer(Int64(cohesionExternal)),
                    "ratio": .float(cohesionRatio),
                 ]), tier: .t1),
        makeUnit(id: startId + 4, entityName: moduleEntity, predicateName: "publicInterface",
                 predicateDomain: "emergence",
                 value: .structured([
                    "count": .integer(Int64(publicCount)),
                    "entities": .string(publicEntities),
                 ]), tier: .t1),
        makeUnit(id: startId + 5, entityName: moduleEntity, predicateName: "interactionProfile",
                 predicateDomain: "emergence",
                 value: .structured([
                    "calls": .integer(Int64(interactionCalls)),
                    "conformsTo": .integer(Int64(interactionConformsTo)),
                    "inherits": .integer(Int64(interactionInherits)),
                 ]), tier: .t1),
        makeUnit(id: startId + 6, entityName: moduleEntity, predicateName: "boundaryProfile",
                 predicateDomain: "emergence",
                 value: .structured([
                    "inboundCalls": .integer(Int64(inboundCalls)),
                    "outboundCalls": .integer(Int64(outboundCalls)),
                    "inboundConformsTo": .integer(0),
                    "outboundConformsTo": .integer(0),
                    "inboundInherits": .integer(0),
                    "outboundInherits": .integer(0),
                 ]), tier: .t1),
    ]
}

// MARK: - Observation Extraction Tests

@Suite("M6 Observation Extraction")
struct M6ObservationExtractionTests {

    @Test("Extracts observations from provider module with public entity")
    func extractProviderPublicEntity() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class")),
            makeUnit(id: 2, entityName: "SessionResolver", predicateName: "language", value: .string("swift")),
        ]
        let moduleUnits = makeProviderModuleUnits()
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations != nil)
        #expect(observations?.moduleName == "Application")
        #expect(observations?.entityName == "SessionResolver")
        #expect(observations?.role?.value == "provider")
        #expect(observations?.visibility?.value == "public-interface")
    }

    @Test("Returns nil when no module entity present")
    func noModuleEntity() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("class")),
        ]
        let allUnits = codeUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations == nil)
    }

    @Test("Module entity names are filtered from code entity list")
    func moduleEntitiesFiltered() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeProviderModuleUnits()
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        #expect(filtered.entityNames == ["UserService"])
        #expect(filtered.entityFacts["module:Application"] == nil)
        #expect(filtered.entityFacts["UserService"] != nil)
    }
}

// MARK: - Suppression Rule Tests

@Suite("M6 Suppression Rules")
struct M6SuppressionRuleTests {

    @Test("Single-file module is fully suppressed")
    func singleFileModuleSuppressed() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "KeychainService", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeProviderModuleUnits(
            moduleName: "Keychain",
            fileCount: 1,
            publicEntities: "KeychainService",
            publicCount: 1
        )
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations == nil)
    }

    @Test("Moderate cohesion (0.5) is suppressed")
    func moderateCohesionSuppressed() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeProviderModuleUnits(
            cohesionRatio: 0.5,
            cohesionInternal: 25,
            cohesionExternal: 25
        )
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations != nil)
        #expect(observations?.cohesion == nil)
    }

    @Test("Mixed role suppressed for internal entity")
    func mixedRoleSuppressedForInternal() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "InternalHelper", predicateName: "kind", value: .string("class")),
        ]
        // Module with mixed role, InternalHelper NOT in public interface.
        var moduleUnits = makeProviderModuleUnits(
            publicEntities: "SessionResolver",
            publicCount: 1
        )
        // Override role to mixed.
        moduleUnits[2] = makeUnit(id: 102, entityName: "module:Application", predicateName: "moduleRole",
                                  predicateDomain: "emergence", value: .string("mixed"), tier: .t1)
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        // Role should be suppressed because entity is internal and role is "mixed".
        #expect(observations?.role == nil)
    }

    @Test("Balanced interaction profile is suppressed")
    func balancedInteractionSuppressed() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeProviderModuleUnits(
            interactionCalls: 10,
            interactionConformsTo: 10,
            interactionInherits: 10
        )
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations?.style == nil)
    }

    @Test("Low relationship count suppresses interaction style")
    func lowRelationshipCountSuppressed() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeProviderModuleUnits(
            interactionCalls: 3,
            interactionConformsTo: 0,
            interactionInherits: 0
        )
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        // 3 total < 5 threshold.
        #expect(observations?.style == nil)
    }

    @Test("Internal entity suppresses visibility")
    func internalEntitySuppressesVisibility() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "InternalHelper", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeProviderModuleUnits(
            publicEntities: "SessionResolver, WorkspaceResolver",
            publicCount: 2
        )
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations?.visibility == nil)
    }

    @Test("Boundary suppressed for internal entity")
    func boundarySuppressedForInternal() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "InternalHelper", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeProviderModuleUnits(
            publicEntities: "SessionResolver",
            publicCount: 1,
            inboundCalls: 20,
            outboundCalls: 2
        )
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations?.boundary == nil)
    }
}

// MARK: - Interpretation Tests

@Suite("M6 Property Interpretation")
struct M6PropertyInterpretationTests {

    @Test("High cohesion interpreted correctly")
    func highCohesion() {
        let codeUnits = [makeUnit(id: 1, entityName: "Svc", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(cohesionRatio: 0.9, cohesionInternal: 90, cohesionExternal: 10)
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        #expect(observations.cohesion?.value == "high")
        #expect(observations.cohesion?.interpretation == "components tightly integrated")
    }

    @Test("Low cohesion interpreted correctly")
    func lowCohesion() {
        let codeUnits = [makeUnit(id: 1, entityName: "Svc", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(cohesionRatio: 0.2, cohesionInternal: 5, cohesionExternal: 20)
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        #expect(observations.cohesion?.value == "low")
        #expect(observations.cohesion?.interpretation == "components relatively independent")
    }

    @Test("Provider role interpreted correctly")
    func providerRole() {
        let codeUnits = [makeUnit(id: 1, entityName: "Svc", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits()
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        #expect(observations.role?.value == "provider")
        #expect(observations.role?.interpretation == "other modules depend on this module")
    }

    @Test("Isolated role interpreted correctly")
    func isolatedRole() {
        let codeUnits = [makeUnit(id: 1, entityName: "Svc", predicateName: "kind", value: .string("class"))]
        var moduleUnits = makeProviderModuleUnits(
            inboundCalls: 0,
            outboundCalls: 0
        )
        moduleUnits[2] = makeUnit(id: 102, entityName: "module:Application", predicateName: "moduleRole",
                                  predicateDomain: "emergence", value: .string("isolated"), tier: .t1)
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        #expect(observations.role?.value == "isolated")
        #expect(observations.role?.interpretation == "self-contained, no cross-module dependencies")
    }

    @Test("Call-dominant style detected")
    func callDominantStyle() {
        let codeUnits = [makeUnit(id: 1, entityName: "Svc", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(
            interactionCalls: 25,
            interactionConformsTo: 3,
            interactionInherits: 2
        )
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        #expect(observations.style?.value == "call-dominant")
    }

    @Test("Protocol-dominant style detected")
    func protocolDominantStyle() {
        let codeUnits = [makeUnit(id: 1, entityName: "Svc", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(
            interactionCalls: 3,
            interactionConformsTo: 25,
            interactionInherits: 2
        )
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        #expect(observations.style?.value == "protocol-dominant")
    }

    @Test("Inbound-heavy boundary detected for public entity")
    func inboundHeavyBoundary() {
        let codeUnits = [makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(
            publicEntities: "SessionResolver",
            publicCount: 1,
            inboundCalls: 20,
            outboundCalls: 2
        )
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        #expect(observations.boundary?.value == "inbound-heavy")
    }
}

// MARK: - Guidance Generation Tests

@Suite("M6 Guidance Generation")
struct M6GuidanceGenerationTests {

    @Test("Public provider gets outward-facing contract guidance")
    func publicProviderGuidance() {
        let codeUnits = [makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(
            publicEntities: "SessionResolver",
            publicCount: 1
        )
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        #expect(observations.guidance.contains("outward-facing contract"))
        #expect(observations.guidance.contains("cross-module impact"))
    }

    @Test("Internal provider gets internal-focused guidance")
    func internalProviderGuidance() {
        let codeUnits = [makeUnit(id: 1, entityName: "InternalHelper", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(
            publicEntities: "SessionResolver",
            publicCount: 1
        )
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        #expect(observations.guidance.contains("serves others"))
        #expect(observations.guidance.contains("internal"))
    }

    @Test("High cohesion appends sibling emphasis guidance")
    func highCohesionGuidance() {
        let codeUnits = [makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(
            cohesionRatio: 0.9,
            cohesionInternal: 90,
            cohesionExternal: 10,
            publicEntities: "SessionResolver",
            publicCount: 1
        )
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        #expect(observations.guidance.contains("sibling entities"))
    }

    @Test("Isolated role gets self-containment guidance")
    func isolatedGuidance() {
        let codeUnits = [makeUnit(id: 1, entityName: "OCRService", predicateName: "kind", value: .string("class"))]
        var moduleUnits = makeProviderModuleUnits(
            moduleName: "OCR",
            publicEntities: "",
            publicCount: 0,
            inboundCalls: 0,
            outboundCalls: 0
        )
        moduleUnits[2] = makeUnit(id: 102, entityName: "module:OCR", predicateName: "moduleRole",
                                  predicateDomain: "emergence", value: .string("isolated"), tier: .t1)
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        #expect(observations.guidance.contains("self-containment"))
    }
}

// MARK: - Prompt Formatting Tests

@Suite("M6 Prompt Formatting")
struct M6PromptFormattingTests {

    @Test("Observation block contains all present fields")
    func observationBlockFormat() {
        let codeUnits = [makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(
            cohesionRatio: 0.9,
            cohesionInternal: 90,
            cohesionExternal: 10,
            publicEntities: "SessionResolver",
            publicCount: 1,
            inboundCalls: 20,
            outboundCalls: 2
        )
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        let formatted = observations.formatForPrompt()

        #expect(formatted.contains("MODULE OBSERVATIONS — SessionResolver"))
        #expect(formatted.contains("module:     Application"))
        #expect(formatted.contains("role:       provider"))
        #expect(formatted.contains("visibility: public-interface"))
        #expect(formatted.contains("cohesion:   high"))
        #expect(formatted.contains("guidance:"))
    }

    @Test("Suppressed fields are absent from formatted output")
    func suppressedFieldsAbsent() {
        let codeUnits = [makeUnit(id: 1, entityName: "InternalHelper", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(
            cohesionRatio: 0.5,
            cohesionInternal: 25,
            cohesionExternal: 25,
            publicEntities: "SessionResolver",
            publicCount: 1,
            interactionCalls: 10,
            interactionConformsTo: 10,
            interactionInherits: 10
        )
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        let formatted = observations.formatForPrompt()

        #expect(!formatted.contains("visibility:"))
        #expect(!formatted.contains("cohesion:"))
        #expect(!formatted.contains("style:"))
        #expect(!formatted.contains("boundary:"))
    }

    @Test("Context summary includes compact module line")
    func contextSummaryModuleLine() {
        let codeUnits = [makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(
            publicEntities: "SessionResolver",
            publicCount: 1
        )
        let allUnits = (codeUnits + moduleUnits).map { contextUnit(from: $0) }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        let summary = observations.formatForContextSummary()

        #expect(summary.contains("Module: Application"))
        #expect(summary.contains("provider"))
        #expect(summary.contains("public-interface"))
    }
}

// MARK: - Engine Integration Tests

private final class M6MockAIProvider: AIProviderProtocol, @unchecked Sendable {
    var lastSystemPrompt: String = ""
    var lastUserContent: String = ""
    var completionResponse: String = "Test explanation."

    func generateCompletion(
        userContent: String,
        systemPrompt: String,
        mode: String?
    ) async throws -> String {
        lastSystemPrompt = systemPrompt
        lastUserContent = userContent
        return completionResponse
    }

    func streamChat(
        messages: [AIMessage],
        systemPrompt: String,
        mode: String?,
        contextTier: String?,
        explanationProfile: String?,
        language: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        lastSystemPrompt = systemPrompt
        return AsyncThrowingStream { continuation in
            continuation.yield(completionResponse)
            continuation.finish()
        }
    }

    func validateConnection() async throws {}
}

@Suite("M6 Explain Engine Integration")
struct M6ExplainEngineIntegrationTests {

    @Test("Explain system prompt includes module instruction when observations present")
    func systemPromptIncludesModuleInstruction() async throws {
        let mockProvider = M6MockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = [makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(publicEntities: "SessionResolver", publicCount: 1)

        let frame = makeFrame(units: codeUnits + moduleUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(mockProvider.lastSystemPrompt.contains("MODULE OBSERVATIONS"))
    }

    @Test("Explain system prompt omits module instruction when no module entity")
    func systemPromptOmitsModuleInstructionWhenNoModule() async throws {
        let mockProvider = M6MockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = [makeUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("class"))]

        let frame = makeFrame(units: codeUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(!mockProvider.lastSystemPrompt.contains("MODULE OBSERVATIONS"))
    }

    @Test("Explain user prompt contains MODULE OBSERVATIONS block")
    func userPromptContainsObservationBlock() async throws {
        let mockProvider = M6MockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = [makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(publicEntities: "SessionResolver", publicCount: 1)

        let frame = makeFrame(units: codeUnits + moduleUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(mockProvider.lastUserContent.contains("MODULE OBSERVATIONS — SessionResolver"))
        #expect(mockProvider.lastUserContent.contains("module:     Application"))
        #expect(mockProvider.lastUserContent.contains("guidance:"))
    }

    @Test("Explain user prompt does not contain raw module entity facts")
    func userPromptNoRawModuleFacts() async throws {
        let mockProvider = M6MockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = [makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(publicEntities: "SessionResolver", publicCount: 1)

        let frame = makeFrame(units: codeUnits + moduleUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        // Module entity should NOT appear in the ## Entities section.
        #expect(!mockProvider.lastUserContent.contains("### module:Application"))
    }

    @Test("Explain user prompt still contains code entity facts")
    func userPromptContainsCodeEntityFacts() async throws {
        let mockProvider = M6MockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = [makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(publicEntities: "SessionResolver", publicCount: 1)

        let frame = makeFrame(units: codeUnits + moduleUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(mockProvider.lastUserContent.contains("### SessionResolver"))
        #expect(mockProvider.lastUserContent.contains("kind: class"))
    }

    @Test("Explain with suppressed module (single-file) has no observations")
    func suppressedModuleNoObservations() async throws {
        let mockProvider = M6MockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = [makeUnit(id: 1, entityName: "Service", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(fileCount: 1)

        let frame = makeFrame(units: codeUnits + moduleUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(!mockProvider.lastUserContent.contains("MODULE OBSERVATIONS"))
        #expect(!mockProvider.lastSystemPrompt.contains("MODULE OBSERVATIONS"))
    }
}

@Suite("M6 FollowUp Engine Integration")
struct M6FollowUpEngineIntegrationTests {

    @Test("FollowUp initial invocation includes module observations in prompt")
    func initialInvocationIncludesModuleObservations() async throws {
        let mockProvider = M6MockAIProvider()
        let engine = FollowUpReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = [makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(publicEntities: "SessionResolver", publicCount: 1)

        let frame = makeFrame(units: codeUnits + moduleUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("followup"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(mockProvider.lastUserContent.contains("MODULE OBSERVATIONS — SessionResolver"))
        #expect(output.conversationState != nil)
    }

    @Test("FollowUp conversation state contains module summary")
    func conversationStateContainsModuleSummary() async throws {
        let mockProvider = M6MockAIProvider()
        let engine = FollowUpReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = [makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(publicEntities: "SessionResolver", publicCount: 1)

        let frame = makeFrame(units: codeUnits + moduleUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("followup"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        // Decode the conversation state and check the context summary.
        let state = try JSONDecoder().decode(
            FollowUpReasoningEngine.FollowUpState.self,
            from: output.conversationState!.data
        )

        #expect(state.contextSummary.contains("Module: Application"))
        #expect(state.contextSummary.contains("provider"))
    }

    @Test("FollowUp follow-up system prompt includes module context instruction")
    func followUpSystemPromptIncludesModuleInstruction() {
        let prompt = FollowUpReasoningEngine.followUpSystemPrompt
        #expect(prompt.contains("module-level information"))
        #expect(prompt.contains("cross-file concerns"))
    }

    @Test("FollowUp context summary excludes raw module entity facts")
    func contextSummaryExcludesModuleEntityFacts() async throws {
        let mockProvider = M6MockAIProvider()
        let engine = FollowUpReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = [makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(publicEntities: "SessionResolver", publicCount: 1)

        let frame = makeFrame(units: codeUnits + moduleUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("followup"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        let state = try JSONDecoder().decode(
            FollowUpReasoningEngine.FollowUpState.self,
            from: output.conversationState!.data
        )

        // Context summary should NOT contain raw module facts like "moduleRole: provider"
        // but SHOULD contain the compact module line "Module: Application, provider".
        #expect(!state.contextSummary.contains("module:Application"))
        #expect(state.contextSummary.contains("Module: Application"))
    }
}

// MARK: - Backward Compatibility Tests

@Suite("M6 Backward Compatibility")
struct M6BackwardCompatibilityTests {

    @Test("Explain without module context produces same output as before")
    func explainWithoutModuleContext() async throws {
        let mockProvider = M6MockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = [
            makeUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("struct")),
            makeUnit(id: 2, entityName: "UserService", predicateName: "hasMethod", value: .string("fetchUser")),
        ]

        let frame = makeFrame(units: codeUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        // No module instruction in system prompt.
        #expect(!mockProvider.lastSystemPrompt.contains("MODULE OBSERVATIONS"))
        // Standard entity format in user prompt.
        #expect(mockProvider.lastUserContent.contains("### UserService"))
        #expect(mockProvider.lastUserContent.contains("kind: struct"))
    }

    @Test("Deterministic fallback still works with module context")
    func deterministicFallbackWithModule() async throws {
        let engine = ExplainReasoningEngine(aiProvider: { nil })

        let codeUnits = [makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(publicEntities: "SessionResolver", publicCount: 1)

        let frame = makeFrame(units: codeUnits + moduleUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(output.completeness == .partial)
        #expect(output.content.contains("SessionResolver"))
    }

    @Test("Claims include both code and module entities")
    func claimsIncludeBothEntities() async throws {
        let engine = ExplainReasoningEngine(aiProvider: { nil })

        let codeUnits = [makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class"))]
        let moduleUnits = makeProviderModuleUnits(publicEntities: "SessionResolver", publicCount: 1)

        let frame = makeFrame(units: codeUnits + moduleUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        // Claims should include both the code entity and the module entity.
        let claimContents = output.claims.map(\.content)
        let hasCodeClaim = claimContents.contains { $0.contains("SessionResolver") }
        let hasModuleClaim = claimContents.contains { $0.contains("module:Application") }
        #expect(hasCodeClaim)
        #expect(hasModuleClaim)
    }
}
