// ProjectIntelligenceValidationTests.swift — DecodeTests
// M12: Project Intelligence Validation
//
// Validates that the complete M8–M11 stack (system composition, system emergent
// properties, project-scope context strategy, architecture-aware explanation)
// produces measurably richer understanding compared to module-only context.
//
// Success criteria:
// 1. System + Module context produces richer explanations than module-only
// 2. System observation injection works end-to-end
// 3. Suppression rules work correctly (trivial system, unknown architecture)
// 4. Prompt formatting and ordering is correct
// 5. Context strategy selects system evidence at the correct tier/scope
// 6. Question-aware ordering infrastructure produces correct results
// 7. Graceful degradation when project intelligence is unavailable
// 8. No hallucinated observations appear
// 9. Deterministic output is unchanged for identical inputs
// 10. No pipeline module modifications

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
    let distance = unit.tier == .t1 ? (unit.subject.entityName?.hasPrefix("system:") == true ? 3 : 2) : 0
    return ContextUnit(
        annotatedUnit: AnnotatedUnit(
            unit: unit,
            provenance: EvidenceProvenance(stage: stage, path: ["test"]),
            distance: distance
        ),
        role: ContextRole(stratumName: stratumName, reason: "test")
    )
}

/// Extension to extract entity name from UnitSubject for distance calculation.
private extension UnitSubject {
    var entityName: String? {
        switch self {
        case .entity(let ref): return ref.qualifiedName
        case .pair: return nil
        }
    }
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
        strategyVersion: "test-3.0",
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
            strategyVersion: "test-3.0",
            committedEpoch: Epoch(value: 1),
            budgetInsufficient: false
        )
    )
}

/// Standard code entity units for a class.
private func makeCodeUnits(
    entityName: String = "SessionResolver",
    startId: UInt64 = 1
) -> [AtomicUnit] {
    [
        makeUnit(id: startId, entityName: entityName, predicateName: "kind", value: .string("class")),
        makeUnit(id: startId + 1, entityName: entityName, predicateName: "language", value: .string("swift")),
        makeUnit(id: startId + 2, entityName: entityName, predicateName: "signature",
                 value: .string("class \(entityName)")),
    ]
}

/// Standard module units for a multi-file provider module.
private func makeModuleUnits(
    moduleName: String = "Application",
    fileCount: Int = 5,
    publicEntities: String = "SessionResolver, ContextBuilderService",
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
                    "ratio": .float(0.85),
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

/// Standard system units for a layered multi-module system.
private func makeSystemUnits(
    systemName: String = "Decode",
    moduleCount: Int = 8,
    totalFileCount: Int = 120,
    totalEntityCount: Int = 450,
    architectureStyle: String = "layered",
    architectureEvidence: String = "Presentation → Application → Domain → Infrastructure",
    layerCount: Int = 4,
    hasCycles: Bool = false,
    violationCount: Int = 0,
    totalEdges: Int = 52,
    startId: UInt64 = 200
) -> [AtomicUnit] {
    let systemEntity = "system:\(systemName)"
    return [
        makeUnit(id: startId, entityName: systemEntity, predicateName: "kind",
                 predicateDomain: "structure", value: .string("system"), tier: .t1),
        makeUnit(id: startId + 1, entityName: systemEntity, predicateName: "moduleCount",
                 predicateDomain: "composition", value: .string(String(moduleCount)), tier: .t1),
        makeUnit(id: startId + 2, entityName: systemEntity, predicateName: "totalFileCount",
                 predicateDomain: "composition", value: .string(String(totalFileCount)), tier: .t1),
        makeUnit(id: startId + 3, entityName: systemEntity, predicateName: "totalEntityCount",
                 predicateDomain: "composition", value: .string(String(totalEntityCount)), tier: .t1),
        makeUnit(id: startId + 4, entityName: systemEntity, predicateName: "architectureStyle",
                 predicateDomain: "emergence",
                 value: .structured([
                    "style": .string(architectureStyle),
                    "evidence": .string(architectureEvidence),
                 ]), tier: .t1),
        makeUnit(id: startId + 5, entityName: systemEntity, predicateName: "dependencyDirection",
                 predicateDomain: "emergence",
                 value: .structured([
                    "layerCount": .integer(Int64(layerCount)),
                    "hasCycles": .boolean(hasCycles),
                    "violationCount": .integer(Int64(violationCount)),
                    "totalEdges": .integer(Int64(totalEdges)),
                 ]), tier: .t1),
    ]
}

/// Adds cross-cutting patterns to a system entity.
private func makeCrossCuttingUnit(
    systemName: String = "Decode",
    patterns: String = "[AIProviderProtocol(5), DatabaseProtocol(4)]",
    threshold: Int = 3,
    id: UInt64 = 210
) -> AtomicUnit {
    makeUnit(id: id, entityName: "system:\(systemName)", predicateName: "crossCuttingPatterns",
             predicateDomain: "emergence",
             value: .structured([
                "patterns": .string(patterns),
                "threshold": .integer(Int64(threshold)),
             ]), tier: .t1)
}

/// Adds technology distribution to a system entity.
private func makeTechnologyUnit(
    systemName: String = "Decode",
    languages: String = "[Swift(92.5), Python(7.5)]",
    primary: String = "Swift",
    id: UInt64 = 211
) -> AtomicUnit {
    makeUnit(id: id, entityName: "system:\(systemName)", predicateName: "technologyDistribution",
             predicateDomain: "emergence",
             value: .structured([
                "languages": .string(languages),
                "primary": .string(primary),
             ]), tier: .t1)
}

/// Adds module interaction map to a system entity.
private func makeInteractionUnit(
    systemName: String = "Decode",
    edges: String = "[Application->Domain(calls:25, conformsTo:3, inherits:0), Presentation->Application(calls:15, conformsTo:2, inherits:1)]",
    id: UInt64 = 212
) -> AtomicUnit {
    makeUnit(id: id, entityName: "system:\(systemName)", predicateName: "moduleInteractionMap",
             predicateDomain: "emergence",
             value: .structured([
                "edges": .string(edges),
             ]), tier: .t1)
}

/// Mock AI provider that captures prompts.
private final class ValidationMockAIProvider: AIProviderProtocol, @unchecked Sendable {
    var lastSystemPrompt: String = ""
    var lastUserContent: String = ""
    var completionResponse: String = "Test explanation with architectural context."

    func generateCompletion(userContent: String, systemPrompt: String, mode: String?) async throws -> String {
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
            continuation.yield("streamed response")
            continuation.finish()
        }
    }

    func validateConnection() async throws {}
}

// MARK: - M12-V1: System + Module Richness Comparison

@Suite("M12-V1 System + Module vs Module-Only Richness")
struct M12RichnessComparisonTests {

    @Test("System + Module context produces richer observations than module-only")
    func systemModuleRicherThanModuleOnly() {
        let codeUnits = makeCodeUnits()

        // Module-only: code + module
        let moduleOnlyUnits = codeUnits + makeModuleUnits()
        let moduleOnlyKnowledge = ReasoningEngineSupport.extractKnowledge(
            from: moduleOnlyUnits.map { contextUnit(from: $0) }
        )
        let moduleOnlyFiltered = ReasoningEngineSupport.filterProjectEntities(from: moduleOnlyKnowledge)
        let moduleObs = ReasoningEngineSupport.extractModuleObservations(
            from: moduleOnlyKnowledge, codeEntityNames: moduleOnlyFiltered.entityNames
        )
        let systemObsFromModuleOnly = ReasoningEngineSupport.extractSystemObservations(
            from: moduleOnlyKnowledge, codeEntityNames: moduleOnlyFiltered.entityNames
        )

        // System + Module: code + module + system
        let fullUnits = codeUnits + makeModuleUnits() + makeSystemUnits() + [
            makeCrossCuttingUnit(), makeTechnologyUnit(), makeInteractionUnit(),
        ]
        let fullKnowledge = ReasoningEngineSupport.extractKnowledge(
            from: fullUnits.map { contextUnit(from: $0) }
        )
        let fullFiltered = ReasoningEngineSupport.filterProjectEntities(from: fullKnowledge)
        let fullModuleObs = ReasoningEngineSupport.extractModuleObservations(
            from: fullKnowledge, codeEntityNames: fullFiltered.entityNames
        )
        let fullSystemObs = ReasoningEngineSupport.extractSystemObservations(
            from: fullKnowledge,
            codeEntityNames: fullFiltered.entityNames,
            moduleName: fullModuleObs?.moduleName
        )

        // Module-only: module observations present, NO system observations
        #expect(moduleObs != nil)
        #expect(systemObsFromModuleOnly == nil, "Module-only context should not produce system observations")

        // Full: BOTH module and system observations present
        #expect(fullModuleObs != nil)
        #expect(fullSystemObs != nil, "Full context should produce system observations")
        #expect(fullSystemObs?.architecture != nil)
        #expect(fullSystemObs?.dependencies != nil)
        #expect(fullSystemObs?.scale != nil)
    }

    @Test("System observations add architectural information not present in module-only context")
    func systemAddsArchitecturalInfo() {
        let codeUnits = makeCodeUnits()
        let fullUnits = codeUnits + makeModuleUnits() + makeSystemUnits() + [
            makeCrossCuttingUnit(), makeTechnologyUnit(), makeInteractionUnit(),
        ]
        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: fullUnits.map { contextUnit(from: $0) }
        )
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)
        let moduleObs = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )
        let systemObs = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames,
            moduleName: moduleObs?.moduleName
        )!

        let systemPrompt = systemObs.formatForPrompt()
        let modulePrompt = moduleObs?.formatForPrompt() ?? ""

        // System adds architecture, dependencies, scale — not in module
        #expect(systemPrompt.contains("architecture:"))
        #expect(systemPrompt.contains("dependencies:"))
        #expect(systemPrompt.contains("scale:"))
        #expect(!modulePrompt.contains("architecture:"))
        #expect(!modulePrompt.contains("scale:"))
    }

    @Test("Full context prompt is strictly longer than module-only prompt")
    func fullContextPromptLonger() {
        let codeUnits = makeCodeUnits()

        // Module-only prompt
        let moduleUnits = codeUnits + makeModuleUnits()
        let moduleKnowledge = ReasoningEngineSupport.extractKnowledge(
            from: moduleUnits.map { contextUnit(from: $0) }
        )
        let moduleFiltered = ReasoningEngineSupport.filterProjectEntities(from: moduleKnowledge)
        let moduleObs = ReasoningEngineSupport.extractModuleObservations(
            from: moduleKnowledge, codeEntityNames: moduleFiltered.entityNames
        )
        let modulePromptLength = (moduleObs?.formatForPrompt() ?? "").count

        // Full prompt (system + module)
        let fullUnits = codeUnits + makeModuleUnits() + makeSystemUnits()
        let fullKnowledge = ReasoningEngineSupport.extractKnowledge(
            from: fullUnits.map { contextUnit(from: $0) }
        )
        let fullFiltered = ReasoningEngineSupport.filterProjectEntities(from: fullKnowledge)
        let fullModuleObs = ReasoningEngineSupport.extractModuleObservations(
            from: fullKnowledge, codeEntityNames: fullFiltered.entityNames
        )
        let fullSystemObs = ReasoningEngineSupport.extractSystemObservations(
            from: fullKnowledge, codeEntityNames: fullFiltered.entityNames,
            moduleName: fullModuleObs?.moduleName
        )
        let fullPromptLength = (fullSystemObs?.formatForPrompt() ?? "").count + (fullModuleObs?.formatForPrompt() ?? "").count

        #expect(fullPromptLength > modulePromptLength, "Full context should produce a longer prompt than module-only")
    }

    @Test("File-only context produces neither module nor system observations")
    func fileOnlyNoProjectObservations() {
        let codeUnits = makeCodeUnits()
        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: codeUnits.map { contextUnit(from: $0) }
        )
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let moduleObs = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )
        let systemObs = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(moduleObs == nil, "File-only context should produce no module observations")
        #expect(systemObs == nil, "File-only context should produce no system observations")
    }
}

// MARK: - M12-V2: Multi-Module Architecture Explanation

@Suite("M12-V2 Multi-Module Architecture Explanation")
struct M12MultiModuleArchitectureTests {

    @Test("Layered system produces architecture and dependency observations")
    func layeredSystemObservations() {
        let codeUnits = makeCodeUnits()
        let allUnits = codeUnits + makeModuleUnits() + makeSystemUnits()
        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: allUnits.map { contextUnit(from: $0) }
        )
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)
        let moduleObs = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        let systemObs = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames,
            moduleName: moduleObs?.moduleName
        )!

        #expect(systemObs.architecture?.value == "layered")
        #expect(systemObs.dependencies?.interpretation.contains("clean dependency flow") == true)
        #expect(systemObs.scale?.interpretation == "medium-scale system")
    }

    @Test("System with dependency cycles produces cycle warning in observations")
    func cycleWarningInObservations() {
        let codeUnits = makeCodeUnits()
        let systemUnits = makeSystemUnits(hasCycles: true, violationCount: 3)
        let allUnits = codeUnits + makeModuleUnits() + systemUnits
        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: allUnits.map { contextUnit(from: $0) }
        )
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let systemObs = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        #expect(systemObs.dependencies?.interpretation.contains("cycles") == true)
        #expect(systemObs.guidance.contains("cycles"))
    }

    @Test("Cross-cutting entity receives cross-cutting emphasis in guidance")
    func crossCuttingEntityEmphasis() {
        let codeUnits = makeCodeUnits(entityName: "AIProviderProtocol")
        let systemUnits = makeSystemUnits() + [makeCrossCuttingUnit()]
        let allUnits = codeUnits + makeModuleUnits() + systemUnits
        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: allUnits.map { contextUnit(from: $0) }
        )
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let systemObs = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        #expect(systemObs.crossCutting != nil)
        #expect(systemObs.crossCutting?.interpretation.contains("cross-cutting concern") == true)
        #expect(systemObs.guidance.contains("cross-module impact"))
    }

    @Test("Module interaction observation filters to the explained entity's module")
    func interactionFiltering() {
        let codeUnits = makeCodeUnits()
        let systemUnits = makeSystemUnits() + [makeInteractionUnit()]
        let allUnits = codeUnits + makeModuleUnits() + systemUnits
        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: allUnits.map { contextUnit(from: $0) }
        )
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let systemObs = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames,
            moduleName: "Application"
        )

        #expect(systemObs?.interactions != nil)
        #expect(systemObs?.interactions?.value.contains("Application") == true)
    }
}

// MARK: - M12-V3: Suppression Validation

@Suite("M12-V3 Suppression Rules")
struct M12SuppressionTests {

    @Test("Trivial system (1 module) is fully suppressed")
    func trivialSystemSuppressed() {
        let codeUnits = makeCodeUnits()
        let systemUnits = makeSystemUnits(moduleCount: 1)
        let allUnits = codeUnits + systemUnits
        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: allUnits.map { contextUnit(from: $0) }
        )
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let systemObs = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(systemObs == nil, "Trivial system should produce no observations")
    }

    @Test("Unknown architecture style is suppressed")
    func unknownArchitectureSuppressed() {
        let codeUnits = makeCodeUnits()
        let systemUnits = makeSystemUnits(architectureStyle: "unknown", architectureEvidence: "")
        let allUnits = codeUnits + systemUnits
        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: allUnits.map { contextUnit(from: $0) }
        )
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let systemObs = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        if let obs = systemObs {
            #expect(obs.architecture == nil, "Unknown architecture should be suppressed")
        }
    }

    @Test("Single-language system suppresses technology observation")
    func singleLanguageSuppressed() {
        let codeUnits = makeCodeUnits()
        let systemUnits = makeSystemUnits() + [
            makeTechnologyUnit(languages: "[Swift(100.0)]", primary: "Swift"),
        ]
        let allUnits = codeUnits + systemUnits
        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: allUnits.map { contextUnit(from: $0) }
        )
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let systemObs = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(systemObs?.technologies == nil, "Single-language should suppress technology observation")
    }

    @Test("Dependency observation suppressed with fewer than 2 layers")
    func fewLayersSuppressed() {
        let codeUnits = makeCodeUnits()
        let systemUnits = makeSystemUnits(layerCount: 1)
        let allUnits = codeUnits + systemUnits
        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: allUnits.map { contextUnit(from: $0) }
        )
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let systemObs = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(systemObs?.dependencies == nil, "< 2 layers should suppress dependency observation")
    }

    @Test("Interaction observation suppressed when no module name provided")
    func interactionSuppressedWithoutModule() {
        let codeUnits = makeCodeUnits()
        let systemUnits = makeSystemUnits() + [makeInteractionUnit()]
        let allUnits = codeUnits + systemUnits
        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: allUnits.map { contextUnit(from: $0) }
        )
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let systemObs = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge, codeEntityNames: filtered.entityNames, moduleName: nil
        )

        #expect(systemObs?.interactions == nil)
    }

    @Test("No cross-cutting patterns produces nil cross-cutting observation")
    func noCrossCuttingPatterns() {
        let codeUnits = makeCodeUnits()
        // System without cross-cutting unit
        let allUnits = codeUnits + makeSystemUnits()
        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: allUnits.map { contextUnit(from: $0) }
        )
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let systemObs = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(systemObs?.crossCutting == nil)
    }
}

// MARK: - M12-V4: Prompt Formatting and Ordering

@Suite("M12-V4 Prompt Formatting and Ordering")
struct M12PromptFormattingTests {

    @Test("System observations block appears before module observations in user prompt")
    func systemBeforeModuleInUserPrompt() async throws {
        let mockProvider = ValidationMockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = makeCodeUnits()
        let moduleUnits = makeModuleUnits()
        let systemUnits = makeSystemUnits()
        let frame = makeFrame(units: codeUnits + moduleUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        let prompt = mockProvider.lastUserContent
        if let sysPos = prompt.range(of: "SYSTEM OBSERVATIONS"),
           let modPos = prompt.range(of: "MODULE OBSERVATIONS") {
            #expect(sysPos.lowerBound < modPos.lowerBound, "System observations must come before module observations")
        }
        #expect(prompt.contains("SYSTEM OBSERVATIONS"))
    }

    @Test("System observations block appears before entities section in user prompt")
    func systemBeforeEntitiesInUserPrompt() async throws {
        let mockProvider = ValidationMockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = makeCodeUnits()
        let systemUnits = makeSystemUnits()
        let frame = makeFrame(units: codeUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        let prompt = mockProvider.lastUserContent
        if let sysPos = prompt.range(of: "SYSTEM OBSERVATIONS"),
           let entPos = prompt.range(of: "## Entities") {
            #expect(sysPos.lowerBound < entPos.lowerBound, "System observations must come before entities")
        }
    }

    @Test("Raw system entity facts do not appear in entities section")
    func noRawSystemFacts() async throws {
        let mockProvider = ValidationMockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = makeCodeUnits()
        let systemUnits = makeSystemUnits()
        let frame = makeFrame(units: codeUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(!mockProvider.lastUserContent.contains("### system:Decode"), "Raw system entity should not appear in entities section")
    }

    @Test("Raw module entity facts do not appear in entities section")
    func noRawModuleFacts() async throws {
        let mockProvider = ValidationMockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = makeCodeUnits()
        let moduleUnits = makeModuleUnits()
        let systemUnits = makeSystemUnits()
        let frame = makeFrame(units: codeUnits + moduleUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(!mockProvider.lastUserContent.contains("### module:Application"), "Raw module entity should not appear in entities section")
    }

    @Test("System prompt includes system instruction when system observations present")
    func systemPromptInstruction() async throws {
        let mockProvider = ValidationMockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = makeCodeUnits()
        let systemUnits = makeSystemUnits()
        let frame = makeFrame(units: codeUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(mockProvider.lastSystemPrompt.contains("SYSTEM OBSERVATIONS"))
    }

    @Test("System prompt omits system instruction when no system evidence")
    func systemPromptOmitsWithoutEvidence() async throws {
        let mockProvider = ValidationMockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = makeCodeUnits()
        let frame = makeFrame(units: codeUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(!mockProvider.lastSystemPrompt.contains("SYSTEM OBSERVATIONS"))
    }
}

// MARK: - M12-V5: Context Strategy Validation

@Suite("M12-V5 Context Strategy Structure")
struct M12ContextStrategyTests {

    @Test("Explain strategy v3 has project stratum selecting T1 scope evidence")
    func explainProjectStratum() {
        let explain = ContextStrategies.explain
        let projectStratum = explain.strata.first { $0.name == "project" }!

        #expect(projectStratum.selectionCriteria.stage == .scope)
        #expect(projectStratum.selectionCriteria.minTier == .t1)
        #expect(projectStratum.selectionCriteria.maxTier == .t1)
        #expect(projectStratum.budgetFraction == 0.15)
    }

    @Test("Project and scope strata are tier-disjoint (SI-2 compliance)")
    func tierDisjointness() {
        let explain = ContextStrategies.explain
        let projectStratum = explain.strata.first { $0.name == "project" }!
        let scopeStratum = explain.strata.first { $0.name == "scope" }!

        // Both share stage: .scope, but tiers are disjoint
        #expect(projectStratum.selectionCriteria.stage == .scope)
        #expect(scopeStratum.selectionCriteria.stage == .scope)
        #expect(projectStratum.selectionCriteria.minTier == .t1)
        #expect(scopeStratum.selectionCriteria.maxTier == .t0)
        // T0 maxTier vs T1 minTier = disjoint
    }

    @Test("Improve strategy has no project stratum")
    func improveNoProject() {
        let improve = ContextStrategies.improve
        let stratumNames = improve.strata.map(\.name)
        #expect(!stratumNames.contains("project"))
    }

    @Test("Followup strategy has project stratum matching explain")
    func followupProjectStratum() {
        let followup = ContextStrategies.followup
        let explainProject = ContextStrategies.explain.strata.first { $0.name == "project" }!
        let followupProject = followup.strata.first { $0.name == "project" }!

        #expect(followupProject.selectionCriteria.stage == explainProject.selectionCriteria.stage)
        #expect(followupProject.selectionCriteria.minTier == explainProject.selectionCriteria.minTier)
        #expect(followupProject.selectionCriteria.maxTier == explainProject.selectionCriteria.maxTier)
    }

    @Test("All budget fractions sum to 1.0 for explain, followup, and improve")
    func budgetFractionsSum() {
        for (name, strategy) in [("explain", ContextStrategies.explain),
                                  ("followup", ContextStrategies.followup),
                                  ("improve", ContextStrategies.improve)] {
            let total = strategy.strata.reduce(0.0) { $0 + $1.budgetFraction }
            #expect(abs(total - 1.0) < 0.001, "Budget fractions for \(name) must sum to 1.0")
        }
    }
}

// MARK: - M12-V6: Retrieval Scope Validation

@Suite("M12-V6 Retrieval Scope")
struct M12RetrievalScopeTests {

    @Test("Explain purpose defaults to system scope")
    func explainDefaultsToSystem() {
        let result = QuestionClassifier.classify(purpose: "explain", questionHint: nil)
        #expect(result.scope == RetrievalScope.system)
    }

    @Test("Followup purpose defaults to system scope")
    func followupDefaultsToSystem() {
        let result = QuestionClassifier.classify(purpose: "followup", questionHint: nil)
        #expect(result.scope == RetrievalScope.system)
    }

    @Test("Improve purpose defaults to local scope")
    func improveDefaultsToLocal() {
        let result = QuestionClassifier.classify(purpose: "improve", questionHint: nil)
        #expect(result.scope == RetrievalScope.local)
    }

    @Test("Overview keywords maintain system scope")
    func overviewKeywordsSystem() {
        let result = QuestionClassifier.classify(purpose: "explain", questionHint: "Give me an overview of this")
        #expect(result.scope >= RetrievalScope.system)
    }

    @Test("Architecture keywords maintain system scope")
    func architectureKeywordsSystem() {
        let result = QuestionClassifier.classify(purpose: "explain", questionHint: "What is the architecture here?")
        #expect(result.scope >= RetrievalScope.system)
    }
}

// MARK: - M12-V7: Question-Aware Ordering

@Suite("M12-V7 Question-Aware Observation Ordering")
struct M12QuestionAwareOrderingTests {

    @Test("Why questions prioritize architecture")
    func whyPrioritizesArchitecture() {
        let order = ReasoningEngineSupport.questionAwareOrder(questionHint: "Why does this module exist?")
        #expect(order?[0] == .architecture)
    }

    @Test("Impact questions prioritize dependencies and cross-cutting")
    func impactPrioritizesDeps() {
        let order = ReasoningEngineSupport.questionAwareOrder(questionHint: "What is the impact of changing this?")
        #expect(order?[0] == .dependencies)
        #expect(order?[1] == .crossCutting)
    }

    @Test("Overview questions prioritize architecture and scale")
    func overviewPrioritizesScale() {
        let order = ReasoningEngineSupport.questionAwareOrder(questionHint: "Give me a high-level overview")
        #expect(order?[0] == .architecture)
        #expect(order?[1] == .scale)
    }

    @Test("Narrow syntax questions should suppress system observations")
    func narrowSyntaxSuppresses() {
        #expect(ReasoningEngineSupport.shouldSuppressSystemForNarrowQuestion(questionHint: "What does this line do?") == true)
        #expect(ReasoningEngineSupport.shouldSuppressSystemForNarrowQuestion(questionHint: "just this function") == true)
    }

    @Test("Broad questions do not suppress system observations")
    func broadDoesNotSuppress() {
        #expect(ReasoningEngineSupport.shouldSuppressSystemForNarrowQuestion(questionHint: "How does this work?") == false)
        #expect(ReasoningEngineSupport.shouldSuppressSystemForNarrowQuestion(questionHint: nil) == false)
    }

    @Test("Prioritized order respects all 6 observation keys")
    func allKeysRepresented() {
        let order = ReasoningEngineSupport.questionAwareOrder(questionHint: "Why does this exist?")!
        let allKeys = Set(SystemObservations.ObservationKey.allCases)
        let orderKeys = Set(order)
        #expect(allKeys == orderKeys, "All observation keys must be represented in prioritized order")
    }
}

// MARK: - M12-V8: Graceful Degradation

@Suite("M12-V8 Graceful Degradation")
struct M12GracefulDegradationTests {

    @Test("Explain engine produces valid output without AI provider and system context")
    func deterministicWithSystemContext() async throws {
        let engine = ExplainReasoningEngine(aiProvider: { nil })
        let codeUnits = makeCodeUnits()
        let systemUnits = makeSystemUnits()
        let frame = makeFrame(units: codeUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(!output.content.isEmpty)
        #expect(output.completeness == .partial)
        #expect(!output.claims.isEmpty)
    }

    @Test("FollowUp engine produces valid output without AI provider and system context")
    func followUpDeterministicWithSystemContext() async throws {
        let engine = FollowUpReasoningEngine(aiProvider: { nil })
        let codeUnits = makeCodeUnits()
        let systemUnits = makeSystemUnits()
        let frame = makeFrame(units: codeUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("followup"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(!output.content.isEmpty)
        #expect(output.completeness == .partial)
        // Deterministic FollowUp still encodes conversation state
        #expect(output.conversationState != nil)
    }

    @Test("Empty context frame produces insufficient output")
    func emptyContextFrame() async throws {
        let engine = ExplainReasoningEngine(aiProvider: { nil })
        let frame = makeFrame(units: [])
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(output.completeness == .insufficient)
    }

    @Test("System context without code entities still produces observations")
    func systemWithoutCodeEntities() {
        // Edge case: only system entity, no code entities
        let systemUnits = makeSystemUnits()
        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: systemUnits.map { contextUnit(from: $0) }
        )
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let systemObs = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        // Should still produce observations (entityName defaults to "unknown")
        #expect(systemObs != nil)
        #expect(systemObs?.entityName == "unknown")
    }
}

// MARK: - M12-V9: No Hallucinated Observations

@Suite("M12-V9 Hallucination Prevention")
struct M12HallucinationPreventionTests {

    @Test("No architecture observation without architectureStyle fact")
    func noArchitectureWithoutFact() {
        let systemEntity = "system:TestSystem"
        let units: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
            makeUnit(id: 200, entityName: systemEntity, predicateName: "kind",
                     predicateDomain: "structure", value: .string("system"), tier: .t1),
            makeUnit(id: 201, entityName: systemEntity, predicateName: "moduleCount",
                     predicateDomain: "composition", value: .string("5"), tier: .t1),
        ]
        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: units.map { contextUnit(from: $0) }
        )
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let systemObs = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(systemObs?.architecture == nil, "No architecture observation without evidence")
    }

    @Test("No dependency observation without dependencyDirection fact")
    func noDependencyWithoutFact() {
        let systemEntity = "system:TestSystem"
        let units: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
            makeUnit(id: 200, entityName: systemEntity, predicateName: "kind",
                     predicateDomain: "structure", value: .string("system"), tier: .t1),
            makeUnit(id: 201, entityName: systemEntity, predicateName: "moduleCount",
                     predicateDomain: "composition", value: .string("5"), tier: .t1),
        ]
        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: units.map { contextUnit(from: $0) }
        )
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let systemObs = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )

        #expect(systemObs?.dependencies == nil, "No dependency observation without evidence")
    }

    @Test("Observations only contain values grounded in actual facts")
    func observationsGroundedInFacts() {
        let codeUnits = makeCodeUnits()
        let systemUnits = makeSystemUnits(architectureStyle: "layered", layerCount: 4, hasCycles: false, violationCount: 0)
        let allUnits = codeUnits + systemUnits
        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: allUnits.map { contextUnit(from: $0) }
        )
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let systemObs = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge, codeEntityNames: filtered.entityNames
        )!

        // Architecture value must match the input
        #expect(systemObs.architecture?.value == "layered")
        // Dependencies must reflect the actual input (no cycles, 0 violations)
        #expect(systemObs.dependencies?.value.contains("no cycles") == true)
        #expect(systemObs.dependencies?.value.contains("0 violations") == true)
        // No observations should mention data not in the input
        #expect(systemObs.crossCutting == nil, "No cross-cutting without cross-cutting facts")
        #expect(systemObs.technologies == nil, "No technology without technology facts")
        #expect(systemObs.interactions == nil, "No interactions without interaction facts")
    }

    @Test("Deterministic output is identical for identical inputs")
    func deterministicStability() async throws {
        let engine = ExplainReasoningEngine(aiProvider: { nil })
        let codeUnits = makeCodeUnits()
        let systemUnits = makeSystemUnits()
        let frame = makeFrame(units: codeUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        let output1 = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)
        let output2 = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(output1.content == output2.content, "Identical inputs must produce identical deterministic output")
        #expect(output1.claims.count == output2.claims.count)
    }
}

// MARK: - M12-V10: FollowUp Engine Integration

@Suite("M12-V10 FollowUp Engine Project Integration")
struct M12FollowUpIntegrationTests {

    @Test("FollowUp initial invocation includes system observations in user prompt")
    func followUpInitialSystemObs() async throws {
        let mockProvider = ValidationMockAIProvider()
        let engine = FollowUpReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = makeCodeUnits()
        let moduleUnits = makeModuleUnits()
        let systemUnits = makeSystemUnits()
        let frame = makeFrame(units: codeUnits + moduleUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("followup"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(mockProvider.lastUserContent.contains("SYSTEM OBSERVATIONS"))
        #expect(output.conversationState != nil)
    }

    @Test("FollowUp context summary encodes system information for subsequent turns")
    func followUpContextSummarySystem() async throws {
        let mockProvider = ValidationMockAIProvider()
        let engine = FollowUpReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = makeCodeUnits()
        let systemUnits = makeSystemUnits()
        let frame = makeFrame(units: codeUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("followup"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        let stateData = output.conversationState!.data
        let state = try JSONDecoder().decode(FollowUpReasoningEngine.FollowUpState.self, from: stateData)

        #expect(state.contextSummary.contains("System:"), "Context summary should include system information")
        #expect(state.contextSummary.contains("Decode"))
    }

    @Test("FollowUp system prompt includes system context instruction")
    func followUpSystemPromptInstruction() {
        let prompt = FollowUpReasoningEngine.followUpSystemPrompt
        #expect(prompt.contains("system-level"), "Follow-up system prompt should reference system-level context")
    }

    @Test("FollowUp with both module and system in context summary")
    func followUpBothModuleAndSystem() async throws {
        let mockProvider = ValidationMockAIProvider()
        let engine = FollowUpReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = makeCodeUnits()
        let moduleUnits = makeModuleUnits()
        let systemUnits = makeSystemUnits()
        let frame = makeFrame(units: codeUnits + moduleUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("followup"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)
        let stateData = output.conversationState!.data
        let state = try JSONDecoder().decode(FollowUpReasoningEngine.FollowUpState.self, from: stateData)

        #expect(state.contextSummary.contains("System:"))
        #expect(state.contextSummary.contains("Module:"))
    }
}

// MARK: - M12-V11: Improve Engine Isolation

@Suite("M12-V11 Improve Engine Isolation")
struct M12ImproveIsolationTests {

    @Test("Improve engine does not inject system observations")
    func improveNoSystemObservations() async throws {
        let mockProvider = ValidationMockAIProvider()
        mockProvider.completionResponse = "<improvement_summary>Code is clean.</improvement_summary>"

        let engine = ImproveReasoningEngine(aiProvider: { mockProvider })

        let codeUnits = makeCodeUnits()
        let systemUnits = makeSystemUnits()
        let frame = makeFrame(units: codeUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("improve"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(!mockProvider.lastUserContent.contains("SYSTEM OBSERVATIONS"), "Improve should not inject system observations")
        #expect(!mockProvider.lastUserContent.contains("MODULE OBSERVATIONS"), "Improve should not inject module observations")
    }
}

// MARK: - M12-V12: filterProjectEntities End-to-End

@Suite("M12-V12 filterProjectEntities End-to-End")
struct M12FilterProjectEntitiesTests {

    @Test("filterProjectEntities removes both module and system, preserves code entities")
    func filtersCorrectly() {
        let codeUnits = makeCodeUnits(entityName: "SessionResolver")
        let moduleUnits = makeModuleUnits()
        let systemUnits = makeSystemUnits()
        let allUnits = codeUnits + moduleUnits + systemUnits

        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: allUnits.map { contextUnit(from: $0) }
        )

        // Before filtering: all entity types present
        #expect(knowledge.entityNames.contains("SessionResolver"))
        #expect(knowledge.entityNames.contains(where: { $0.hasPrefix("module:") }))
        #expect(knowledge.entityNames.contains(where: { $0.hasPrefix("system:") }))

        // After filtering: only code entities
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)
        #expect(filtered.entityNames.contains("SessionResolver"))
        #expect(!filtered.entityNames.contains(where: { $0.hasPrefix("module:") }))
        #expect(!filtered.entityNames.contains(where: { $0.hasPrefix("system:") }))
    }

    @Test("filterProjectEntities preserves fact content for remaining entities")
    func preservesFactContent() {
        let codeUnits = makeCodeUnits(entityName: "SessionResolver")
        let systemUnits = makeSystemUnits()
        let allUnits = codeUnits + systemUnits

        let knowledge = ReasoningEngineSupport.extractKnowledge(
            from: allUnits.map { contextUnit(from: $0) }
        )
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        // Facts for SessionResolver should be preserved
        let facts = filtered.entityFacts["SessionResolver"]
        #expect(facts != nil)
        #expect(facts!.contains(where: { $0.predicate == "kind" }))
        #expect(facts!.contains(where: { $0.predicate == "language" }))
    }
}
