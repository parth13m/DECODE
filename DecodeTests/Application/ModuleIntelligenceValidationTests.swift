// ModuleIntelligenceValidationTests.swift — DecodeTests
// E2-00: Module Intelligence Validation (M6 ConsumerRuntime support)
//
// Validates that the complete M1–M6 stack produces measurably richer
// understanding for cross-file questions compared to file-only explanations.
//
// This is the gate between Phase 1 (Module Intelligence) and Phase 2
// (Project Intelligence). Success criteria:
// 1. Multi-file module explanations contain module-context framing
// 2. Single-file module suppression works end-to-end
// 3. Module framing is woven naturally, not a separate section
// 4. Follow-up references module context reactively
// 5. No performance regression
// 6. No pipeline module modifications

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
    tier: Tier = .t0,
    filePath: String = "Application/Service.swift"
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
            filePath: filePath,
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
private func contextUnit(from unit: AtomicUnit, stratumName: String = "primary") -> ContextUnit {
    let stage: EvidenceStage = unit.tier == .t1 ? .scope : .direct
    return ContextUnit(
        annotatedUnit: AnnotatedUnit(
            unit: unit,
            provenance: EvidenceProvenance(stage: stage, path: ["test"]),
            distance: unit.tier == .t1 ? 2 : 0
        ),
        role: ContextRole(stratumName: stratumName, reason: "test")
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

/// Standard module units for a multi-file provider module.
private func makeProviderModuleUnits(
    moduleName: String = "Application",
    fileCount: Int = 5,
    cohesionRatio: Double = 0.85,
    publicEntities: String = "UserService, UserRepository",
    publicCount: Int = 2,
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
                    "internal": .integer(45),
                    "external": .integer(8),
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
                    "calls": .integer(30),
                    "conformsTo": .integer(5),
                    "inherits": .integer(2),
                 ]), tier: .t1),
        makeUnit(id: startId + 6, entityName: moduleEntity, predicateName: "boundaryProfile",
                 predicateDomain: "emergence",
                 value: .structured([
                    "inboundCalls": .integer(15),
                    "outboundCalls": .integer(3),
                    "inboundConformsTo": .integer(0),
                    "outboundConformsTo": .integer(0),
                    "inboundInherits": .integer(0),
                    "outboundInherits": .integer(0),
                 ]), tier: .t1),
    ]
}

/// Single-file module units (should be suppressed).
private func makeSingleFileModuleUnits(
    moduleName: String = "Helpers",
    startId: UInt64 = 200
) -> [AtomicUnit] {
    let moduleEntity = "module:\(moduleName)"
    return [
        makeUnit(id: startId, entityName: moduleEntity, predicateName: "kind",
                 predicateDomain: "structure", value: .string("module"), tier: .t1),
        makeUnit(id: startId + 1, entityName: moduleEntity, predicateName: "fileCount",
                 predicateDomain: "composition", value: .integer(1), tier: .t1),
        makeUnit(id: startId + 2, entityName: moduleEntity, predicateName: "moduleRole",
                 predicateDomain: "emergence", value: .string("isolated"), tier: .t1),
    ]
}

/// Consumer module units.
private func makeConsumerModuleUnits(
    moduleName: String = "Presentation",
    fileCount: Int = 4,
    startId: UInt64 = 300
) -> [AtomicUnit] {
    let moduleEntity = "module:\(moduleName)"
    return [
        makeUnit(id: startId, entityName: moduleEntity, predicateName: "kind",
                 predicateDomain: "structure", value: .string("module"), tier: .t1),
        makeUnit(id: startId + 1, entityName: moduleEntity, predicateName: "fileCount",
                 predicateDomain: "composition", value: .integer(Int64(fileCount)), tier: .t1),
        makeUnit(id: startId + 2, entityName: moduleEntity, predicateName: "moduleRole",
                 predicateDomain: "emergence", value: .string("consumer"), tier: .t1),
        makeUnit(id: startId + 3, entityName: moduleEntity, predicateName: "cohesion",
                 predicateDomain: "emergence",
                 value: .structured([
                    "internal": .integer(10),
                    "external": .integer(25),
                    "ratio": .float(0.28),
                 ]), tier: .t1),
        makeUnit(id: startId + 4, entityName: moduleEntity, predicateName: "publicInterface",
                 predicateDomain: "emergence",
                 value: .structured([
                    "count": .integer(1),
                    "entities": .string("MainView"),
                 ]), tier: .t1),
        makeUnit(id: startId + 5, entityName: moduleEntity, predicateName: "interactionProfile",
                 predicateDomain: "emergence",
                 value: .structured([
                    "calls": .integer(20),
                    "conformsTo": .integer(2),
                    "inherits": .integer(0),
                 ]), tier: .t1),
        makeUnit(id: startId + 6, entityName: moduleEntity, predicateName: "boundaryProfile",
                 predicateDomain: "emergence",
                 value: .structured([
                    "inboundCalls": .integer(2),
                    "outboundCalls": .integer(18),
                    "inboundConformsTo": .integer(0),
                    "outboundConformsTo": .integer(0),
                    "inboundInherits": .integer(0),
                    "outboundInherits": .integer(0),
                 ]), tier: .t1),
    ]
}

// MARK: - M7-V1: Multi-File Module Observation Extraction

@Suite("M7-V1 Multi-File Module Observations")
struct M7MultiFileModuleObservationTests {

    @Test("Provider module with public entity produces observations")
    func providerPublicEntity() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("class")),
            makeUnit(id: 2, entityName: "UserService", predicateName: "signature", value: .string("class UserService")),
        ]
        let moduleUnits = makeProviderModuleUnits()
        let frame = makeFrame(units: codeUnits + moduleUnits)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(observations != nil)
        #expect(observations?.moduleName == "Application")
        #expect(observations?.entityName == "UserService")
        #expect(observations?.role?.value == "provider")
        #expect(observations?.visibility?.value == "public-interface")
        #expect(observations?.cohesion?.value == "high")
    }

    @Test("Consumer module produces consumer role observation")
    func consumerModule() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MainView", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeConsumerModuleUnits()
        let frame = makeFrame(units: codeUnits + moduleUnits)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(observations != nil)
        #expect(observations?.moduleName == "Presentation")
        #expect(observations?.role?.value == "consumer")
        #expect(observations?.cohesion?.value == "low")
    }

    @Test("Module observations contain all expected fields for provider+public")
    func providerPublicFullFields() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeProviderModuleUnits()
        let frame = makeFrame(units: codeUnits + moduleUnits)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        // Provider + public entity: role, visibility, cohesion, style (call-dominant), boundary
        #expect(observations.role != nil)
        #expect(observations.visibility != nil)
        #expect(observations.cohesion != nil)
        #expect(observations.style?.value == "call-dominant")
        #expect(observations.boundary?.value == "inbound-heavy")
        #expect(!observations.guidance.isEmpty)
    }

    @Test("Internal entity in provider module suppresses visibility and boundary")
    func internalEntitySuppression() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "InternalHelper", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeProviderModuleUnits()
        let frame = makeFrame(units: codeUnits + moduleUnits)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(observations != nil)
        // Internal entity: visibility and boundary should be nil
        #expect(observations?.visibility == nil)
        #expect(observations?.boundary == nil)
        // Role should still be present (provider is meaningful for internal entities)
        #expect(observations?.role?.value == "provider")
    }

    @Test("Module with multiple code entities uses first as primary")
    func multipleCodeEntities() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("class")),
            makeUnit(id: 2, entityName: "UserService.fetch", predicateName: "kind", value: .string("method")),
            makeUnit(id: 3, entityName: "UserRepository", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeProviderModuleUnits()
        let frame = makeFrame(units: codeUnits + moduleUnits)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(observations?.entityName == "UserService")
    }
}

// MARK: - M7-V2: Single-File Module Suppression

@Suite("M7-V2 Single-File Module Suppression")
struct M7SingleFileSuppressionTests {

    @Test("Single-file module is fully suppressed")
    func singleFileSuppression() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "Helper", predicateName: "kind", value: .string("struct")),
        ]
        let moduleUnits = makeSingleFileModuleUnits()
        let frame = makeFrame(units: codeUnits + moduleUnits)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(observations == nil, "Single-file module should produce no observations")
    }

    @Test("Single-file suppression occurs regardless of module role")
    func singleFileSuppressesAllRoles() {
        for role in ["provider", "consumer", "mixed", "isolated"] {
            let moduleEntity = "module:SingleDir"
            let units: [AtomicUnit] = [
                makeUnit(id: 1, entityName: "Entity", predicateName: "kind", value: .string("class")),
                makeUnit(id: 10, entityName: moduleEntity, predicateName: "kind",
                         predicateDomain: "structure", value: .string("module"), tier: .t1),
                makeUnit(id: 11, entityName: moduleEntity, predicateName: "fileCount",
                         predicateDomain: "composition", value: .integer(1), tier: .t1),
                makeUnit(id: 12, entityName: moduleEntity, predicateName: "moduleRole",
                         predicateDomain: "emergence", value: .string(role), tier: .t1),
            ]
            let frame = makeFrame(units: units)
            let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
            let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

            let observations = ReasoningEngineSupport.extractModuleObservations(
                from: knowledge, codeEntityNames: filtered.entityNames
            )

            #expect(observations == nil, "Role '\(role)' in single-file module should be suppressed")
        }
    }

    @Test("No module entity produces no observations")
    func noModuleEntity() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "StandaloneClass", predicateName: "kind", value: .string("class")),
            makeUnit(id: 2, entityName: "StandaloneClass", predicateName: "signature", value: .string("class StandaloneClass")),
        ]
        let frame = makeFrame(units: codeUnits)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(observations == nil)
    }
}

// MARK: - M7-V3: Prompt Injection Validation

@Suite("M7-V3 Prompt Injection")
struct M7PromptInjectionTests {

    @Test("Module observations format contains module name and role")
    func promptFormatContent() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeProviderModuleUnits()
        let frame = makeFrame(units: codeUnits + moduleUnits)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        let formatted = observations.formatForPrompt()

        #expect(formatted.contains("MODULE OBSERVATIONS"))
        #expect(formatted.contains("UserService"))
        #expect(formatted.contains("Application"))
        #expect(formatted.contains("provider"))
        #expect(formatted.contains("guidance:"))
    }

    @Test("Module observation block does NOT contain module: prefix in entity section")
    func moduleEntitiesFiltered() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeProviderModuleUnits()
        let allUnits = codeUnits + moduleUnits
        let frame = makeFrame(units: allUnits)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))

        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        // Filtered names should not contain module entities
        #expect(!filtered.entityNames.contains(where: { $0.hasPrefix("module:") }))
        #expect(!filtered.entityFacts.keys.contains(where: { $0.hasPrefix("module:") }))

        // But code entities should remain
        #expect(filtered.entityNames.contains("UserService"))
    }

    @Test("System prompt includes module instruction when observations present")
    func systemPromptInstruction() {
        let instruction = ModuleObservations.systemPromptInstruction

        #expect(instruction.contains("MODULE OBSERVATIONS"))
        #expect(instruction.contains("Do not create a separate module section"))
        #expect(instruction.contains("Weave module framing naturally"))
        #expect(instruction.contains("guidance directive"))
    }

    @Test("Follow-up context instruction is reactive")
    func followUpInstruction() {
        let instruction = ModuleObservations.followUpContextInstruction

        #expect(instruction.contains("module-level"))
        #expect(instruction.contains("cross-file"))
    }

    @Test("Context summary is compact for conversation state")
    func contextSummaryCompact() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeProviderModuleUnits()
        let frame = makeFrame(units: codeUnits + moduleUnits)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        let summary = observations.formatForContextSummary()

        #expect(summary.contains("Application"))
        #expect(summary.contains("provider"))
        // Should be a single line, not multi-line
        #expect(!summary.contains("\n"))
    }
}

// MARK: - M7-V4: ExplainReasoningEngine Module Integration

@Suite("M7-V4 ExplainReasoningEngine Module Integration")
struct M7ExplainEngineIntegrationTests {

    @Test("Deterministic explain output includes module entity information")
    func deterministicOutputWithModule() async throws {
        // Use nil AI provider to get deterministic output
        let engine = ExplainReasoningEngine(aiProvider: { nil })

        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("class")),
            makeUnit(id: 2, entityName: "UserService", predicateName: "signature", value: .string("class UserService")),
            makeUnit(id: 3, entityName: "UserService.fetch", predicateName: "kind", value: .string("method")),
        ]
        let moduleUnits = makeProviderModuleUnits()
        let frame = makeFrame(units: codeUnits + moduleUnits)

        let output = try await engine.reason(
            contextFrame: frame,
            outputSpecification: OutputSpecification(
                purpose: ContextPurpose("explain"),
                outputClass: .human,
                detailLevel: .standard
            ),
            conversationState: nil
        )

        // Deterministic output should include code entity facts
        #expect(!output.content.isEmpty)
        #expect(output.content.contains("UserService"))
        // Should have claims grounded to units
        #expect(!output.claims.isEmpty)
        // Completeness should be partial (deterministic fallback)
        #expect(output.completeness == .partial)
    }

    @Test("AI prompt path filters module entities from entity section")
    func aiPromptFiltersModuleEntities() {
        // Verify the prompt construction path filters module entities.
        // The deterministic fallback shows all entities (raw summary).
        // The AI prompt uses filterModuleEntities + module observations instead.
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeProviderModuleUnits()
        let allUnits = codeUnits + moduleUnits
        let frame = makeFrame(units: allUnits)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))

        // Verify filter removes module entities
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)
        #expect(!filtered.entityNames.contains("module:Application"))
        #expect(filtered.entityNames.contains("UserService"))

        // Verify observations are extracted instead
        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )
        #expect(observations != nil)
        #expect(observations?.moduleName == "Application")
    }

    @Test("Explain engine produces output without module context")
    func explainWithoutModule() async throws {
        let engine = ExplainReasoningEngine(aiProvider: { nil })

        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "SimpleClass", predicateName: "kind", value: .string("class")),
            makeUnit(id: 2, entityName: "SimpleClass", predicateName: "signature", value: .string("class SimpleClass")),
        ]
        let frame = makeFrame(units: codeUnits)

        let output = try await engine.reason(
            contextFrame: frame,
            outputSpecification: OutputSpecification(
                purpose: ContextPurpose("explain"),
                outputClass: .human,
                detailLevel: .standard
            ),
            conversationState: nil
        )

        #expect(!output.content.isEmpty)
        #expect(output.content.contains("SimpleClass"))
    }

    @Test("Single-file module produces no observations for AI prompt")
    func singleFileModuleNoObservationsForAI() {
        // Single-file module: observations are nil, so the AI prompt path
        // would not inject MODULE OBSERVATIONS. The deterministic fallback
        // is a raw summary (shows all entities), but the AI path is clean.
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "Helper", predicateName: "kind", value: .string("struct")),
            makeUnit(id: 2, entityName: "Helper", predicateName: "signature", value: .string("struct Helper")),
        ]
        let moduleUnits = makeSingleFileModuleUnits()
        let allUnits = codeUnits + moduleUnits
        let frame = makeFrame(units: allUnits)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        // Single-file → fully suppressed
        #expect(observations == nil)
        // Code entity still present in filtered output
        #expect(filtered.entityNames.contains("Helper"))
    }
}

// MARK: - M7-V5: Suppression Rules Validation

@Suite("M7-V5 Suppression Rules")
struct M7SuppressionRulesTests {

    @Test("Moderate cohesion (0.3-0.8) is suppressed")
    func moderateCohesionSuppressed() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "Service", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeProviderModuleUnits(cohesionRatio: 0.55) // Moderate
        let frame = makeFrame(units: codeUnits + moduleUnits)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(observations != nil, "Module should still produce observations")
        #expect(observations?.cohesion == nil, "Moderate cohesion should be suppressed")
    }

    @Test("High cohesion (>0.8) is preserved")
    func highCohesionPreserved() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "Service", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeProviderModuleUnits(cohesionRatio: 0.9)
        let frame = makeFrame(units: codeUnits + moduleUnits)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(observations?.cohesion?.value == "high")
    }

    @Test("Low cohesion (<0.3) is preserved")
    func lowCohesionPreserved() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "Service", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeConsumerModuleUnits() // ratio 0.28
        let frame = makeFrame(units: codeUnits + moduleUnits)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(observations?.cohesion?.value == "low")
    }

    @Test("Mixed role suppressed for internal entity")
    func mixedRoleSuppressedForInternal() {
        let moduleEntity = "module:Mixed"
        let units: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "InternalHelper", predicateName: "kind", value: .string("class")),
            makeUnit(id: 10, entityName: moduleEntity, predicateName: "kind",
                     predicateDomain: "structure", value: .string("module"), tier: .t1),
            makeUnit(id: 11, entityName: moduleEntity, predicateName: "fileCount",
                     predicateDomain: "composition", value: .integer(5), tier: .t1),
            makeUnit(id: 12, entityName: moduleEntity, predicateName: "moduleRole",
                     predicateDomain: "emergence", value: .string("mixed"), tier: .t1),
            makeUnit(id: 13, entityName: moduleEntity, predicateName: "publicInterface",
                     predicateDomain: "emergence",
                     value: .structured([
                        "count": .integer(1),
                        "entities": .string("PublicAPI"),
                     ]), tier: .t1),
        ]
        let frame = makeFrame(units: units)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        // InternalHelper is not in publicInterface → mixed role suppressed
        #expect(observations?.role == nil)
    }

    @Test("Balanced interaction profile (no dominant type) suppressed")
    func balancedInteractionSuppressed() {
        let moduleEntity = "module:Balanced"
        let units: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "Entity", predicateName: "kind", value: .string("class")),
            makeUnit(id: 10, entityName: moduleEntity, predicateName: "kind",
                     predicateDomain: "structure", value: .string("module"), tier: .t1),
            makeUnit(id: 11, entityName: moduleEntity, predicateName: "fileCount",
                     predicateDomain: "composition", value: .integer(5), tier: .t1),
            makeUnit(id: 12, entityName: moduleEntity, predicateName: "moduleRole",
                     predicateDomain: "emergence", value: .string("provider"), tier: .t1),
            makeUnit(id: 13, entityName: moduleEntity, predicateName: "interactionProfile",
                     predicateDomain: "emergence",
                     value: .structured([
                        "calls": .integer(10),
                        "conformsTo": .integer(8),
                        "inherits": .integer(7),
                     ]), tier: .t1),
        ]
        let frame = makeFrame(units: units)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(observations?.style == nil, "Balanced interaction should suppress style")
    }

    @Test("Low relationship count (<5) suppresses style")
    func lowRelationshipCountSuppressed() {
        let moduleEntity = "module:Small"
        let units: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "Entity", predicateName: "kind", value: .string("class")),
            makeUnit(id: 10, entityName: moduleEntity, predicateName: "kind",
                     predicateDomain: "structure", value: .string("module"), tier: .t1),
            makeUnit(id: 11, entityName: moduleEntity, predicateName: "fileCount",
                     predicateDomain: "composition", value: .integer(3), tier: .t1),
            makeUnit(id: 12, entityName: moduleEntity, predicateName: "moduleRole",
                     predicateDomain: "emergence", value: .string("isolated"), tier: .t1),
            makeUnit(id: 13, entityName: moduleEntity, predicateName: "interactionProfile",
                     predicateDomain: "emergence",
                     value: .structured([
                        "calls": .integer(3),
                        "conformsTo": .integer(1),
                        "inherits": .integer(0),
                     ]), tier: .t1),
        ]
        let frame = makeFrame(units: units)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(observations?.style == nil, "Low relationship count should suppress style")
    }
}

// MARK: - M7-V6: Guidance Generation Validation

@Suite("M7-V6 Guidance Generation")
struct M7GuidanceGenerationTests {

    @Test("Provider + public entity generates cross-module impact guidance")
    func providerPublicGuidance() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeProviderModuleUnits()
        let frame = makeFrame(units: codeUnits + moduleUnits)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        #expect(observations.guidance.contains("contract") || observations.guidance.contains("cross-module"))
    }

    @Test("Consumer module generates dependency guidance")
    func consumerGuidance() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "InternalWidget", predicateName: "kind", value: .string("class")),
        ]
        let moduleUnits = makeConsumerModuleUnits()
        let frame = makeFrame(units: codeUnits + moduleUnits)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(observations != nil)
        #expect(observations?.guidance.contains("depend") ?? false)
    }

    @Test("Isolated module generates self-containment guidance")
    func isolatedGuidance() {
        let moduleEntity = "module:Utils"
        let units: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MathUtils", predicateName: "kind", value: .string("struct")),
            makeUnit(id: 10, entityName: moduleEntity, predicateName: "kind",
                     predicateDomain: "structure", value: .string("module"), tier: .t1),
            makeUnit(id: 11, entityName: moduleEntity, predicateName: "fileCount",
                     predicateDomain: "composition", value: .integer(3), tier: .t1),
            makeUnit(id: 12, entityName: moduleEntity, predicateName: "moduleRole",
                     predicateDomain: "emergence", value: .string("isolated"), tier: .t1),
        ]
        let frame = makeFrame(units: units)
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: frame.strata.flatMap(\.units))
        let filtered = ReasoningEngineSupport.filterModuleEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(observations != nil)
        #expect(observations?.guidance.lowercased().contains("self-contain") ?? false)
    }
}

// MARK: - M7-V7: Context Strategy Validation

@Suite("M7-V7 Context Strategy Structure")
struct M7ContextStrategyTests {

    @Test("Explain strategy v2 has four strata including module")
    func explainStrategyHasFourStrata() {
        let explain = ContextStrategies.explain

        #expect(explain.strata.count == 4, "Explain strategy must have 4 strata")

        let stratumNames = explain.strata.map(\.name)
        #expect(stratumNames.contains("direct"))
        #expect(stratumNames.contains("relational"))
        #expect(stratumNames.contains("module"))
        #expect(stratumNames.contains("scope"))
    }

    @Test("Module stratum selects T1 scope evidence")
    func moduleStratumTierPartition() {
        let explain = ContextStrategies.explain
        let moduleStratum = explain.strata.first { $0.name == "module" }!

        #expect(moduleStratum.selectionCriteria.stage == .scope, "Module stratum should pull from scope stage")
        #expect(moduleStratum.selectionCriteria.minTier == .t1, "Module stratum should require T1 minimum")
        #expect(moduleStratum.selectionCriteria.maxTier == .t1, "Module stratum should cap at T1")
    }

    @Test("Scope stratum selects T0 scope evidence (no overlap with module)")
    func scopeStratumNoOverlap() {
        let explain = ContextStrategies.explain
        let scopeStratum = explain.strata.first { $0.name == "scope" }!

        #expect(scopeStratum.selectionCriteria.stage == .scope)
        // T0 only — no T1, so no overlap with module stratum
        #expect(scopeStratum.selectionCriteria.maxTier == .t0)
    }

    @Test("Budget fractions sum to 1.0")
    func budgetFractions() {
        let explain = ContextStrategies.explain
        let totalBudget = explain.strata.reduce(0.0) { $0 + $1.budgetFraction }
        #expect(abs(totalBudget - 1.0) < 0.001, "Budget fractions must sum to 1.0")
    }

    @Test("Improve strategy has no module stratum")
    func improveNoModule() {
        let improve = ContextStrategies.improve
        let stratumNames = improve.strata.map(\.name)
        #expect(!stratumNames.contains("module"), "Improve strategy should not have module stratum")
    }

    @Test("Followup strategy mirrors explain with module stratum")
    func followupMirrorsExplain() {
        let followup = ContextStrategies.followup
        #expect(followup.strata.count == 4)
        let stratumNames = followup.strata.map(\.name)
        #expect(stratumNames.contains("module"))
    }
}

// MARK: - M7-V8: Observation Richness Comparison

@Suite("M7-V8 Multi-File vs File-Only Richness")
struct M7RichnessComparisonTests {

    @Test("Multi-file module produces more information than file-only")
    func multiFileRicherThanFileOnly() {
        // File-only: just code entities
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("class")),
            makeUnit(id: 2, entityName: "UserService", predicateName: "signature", value: .string("class UserService")),
            makeUnit(id: 3, entityName: "UserService.fetch", predicateName: "kind", value: .string("method")),
        ]

        let fileOnlyKnowledge = ReasoningEngineSupport.extractKnowledge(
            from: codeUnits.map { contextUnit(from: $0) }
        )
        let fileOnlyFiltered = ReasoningEngineSupport.filterModuleEntities(from: fileOnlyKnowledge)
        let fileOnlyObs = ReasoningEngineSupport.extractModuleObservations(
            from: fileOnlyKnowledge, codeEntityNames: fileOnlyFiltered.entityNames
        )

        // Multi-file: code entities + module context
        let moduleUnits = makeProviderModuleUnits()
        let multiFileKnowledge = ReasoningEngineSupport.extractKnowledge(
            from: (codeUnits + moduleUnits).map { contextUnit(from: $0) }
        )
        let multiFileFiltered = ReasoningEngineSupport.filterModuleEntities(from: multiFileKnowledge)
        let multiFileObs = ReasoningEngineSupport.extractModuleObservations(
            from: multiFileKnowledge, codeEntityNames: multiFileFiltered.entityNames
        )

        // File-only should have no observations
        #expect(fileOnlyObs == nil)

        // Multi-file should have observations with rich content
        #expect(multiFileObs != nil)
        #expect(multiFileObs?.role != nil)
        #expect(multiFileObs?.visibility != nil)
        #expect(multiFileObs?.cohesion != nil)
        #expect(!multiFileObs!.guidance.isEmpty)

        // The formatted prompt block adds information not present in file-only
        let promptBlock = multiFileObs!.formatForPrompt()
        #expect(promptBlock.contains("MODULE OBSERVATIONS"))
        #expect(promptBlock.contains("role:"))
        #expect(promptBlock.contains("visibility:"))
        #expect(promptBlock.contains("cohesion:"))
    }

    @Test("Module observation block is absent for single-file, present for multi-file")
    func observationPresenceComparison() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "Service", predicateName: "kind", value: .string("class")),
        ]

        // Single-file module
        let singleUnits = codeUnits + makeSingleFileModuleUnits(moduleName: "Single")
        let singleKnowledge = ReasoningEngineSupport.extractKnowledge(
            from: singleUnits.map { contextUnit(from: $0) }
        )
        let singleFiltered = ReasoningEngineSupport.filterModuleEntities(from: singleKnowledge)
        let singleObs = ReasoningEngineSupport.extractModuleObservations(
            from: singleKnowledge, codeEntityNames: singleFiltered.entityNames
        )

        // Multi-file module
        let multiUnits = codeUnits + makeProviderModuleUnits(
            publicEntities: "Service", publicCount: 1
        )
        let multiKnowledge = ReasoningEngineSupport.extractKnowledge(
            from: multiUnits.map { contextUnit(from: $0) }
        )
        let multiFiltered = ReasoningEngineSupport.filterModuleEntities(from: multiKnowledge)
        let multiObs = ReasoningEngineSupport.extractModuleObservations(
            from: multiKnowledge, codeEntityNames: multiFiltered.entityNames
        )

        #expect(singleObs == nil, "Single-file module should produce no observations")
        #expect(multiObs != nil, "Multi-file module should produce observations")
    }
}
