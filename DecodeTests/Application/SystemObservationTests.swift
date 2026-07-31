// SystemObservationTests.swift — DecodeTests
// M11: Tests for system observation extraction, suppression, interpretation,
// guidance generation, prompt formatting, question-aware ordering,
// filterProjectEntities, and reasoning engine integration.

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
            distance: 3
        ),
        role: ContextRole(stratumName: "project", reason: "test")
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

/// Builds standard system units for a layered system with common properties.
private func makeSystemUnits(
    systemName: String = "Decode",
    moduleCount: Int = 8,
    totalFileCount: Int = 120,
    totalEntityCount: Int = 450,
    architectureStyle: String = "layered",
    architectureEvidence: String = "4 layers: Presentation → Application → Domain → Infrastructure",
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

// MARK: - Suite 1: System Property Parsing

@Suite("M11-S1 System Property Parsing")
struct SystemPropertyParsingTests {

    @Test("Parses architecture style and evidence")
    func parseArchitectureStyle() {
        let facts: [(predicate: String, value: String, unitId: UnitIdentifier)] = [
            (predicate: "architectureStyle", value: "style: layered, evidence: 4 layers detected", unitId: UnitIdentifier(rawValue: 1)),
        ]
        let props = ReasoningEngineSupport.parseSystemProperties(from: facts)
        #expect(props.architectureStyle == "layered")
        #expect(props.architectureEvidence == "4 layers detected")
    }

    @Test("Parses dependency direction properties")
    func parseDependencyDirection() {
        let facts: [(predicate: String, value: String, unitId: UnitIdentifier)] = [
            (predicate: "dependencyDirection", value: "layerCount: 4, hasCycles: false, violationCount: 2, totalEdges: 50",
             unitId: UnitIdentifier(rawValue: 1)),
        ]
        let props = ReasoningEngineSupport.parseSystemProperties(from: facts)
        #expect(props.layerCount == 4)
        #expect(props.hasCycles == false)
        #expect(props.violationCount == 2)
        #expect(props.totalEdges == 50)
    }

    @Test("Parses module count and totals")
    func parseModuleCountAndTotals() {
        let facts: [(predicate: String, value: String, unitId: UnitIdentifier)] = [
            (predicate: "moduleCount", value: "8", unitId: UnitIdentifier(rawValue: 1)),
            (predicate: "totalFileCount", value: "120", unitId: UnitIdentifier(rawValue: 2)),
            (predicate: "totalEntityCount", value: "450", unitId: UnitIdentifier(rawValue: 3)),
        ]
        let props = ReasoningEngineSupport.parseSystemProperties(from: facts)
        #expect(props.moduleCount == 8)
        #expect(props.totalFileCount == 120)
        #expect(props.totalEntityCount == 450)
    }

    @Test("Parses cross-cutting patterns")
    func parseCrossCuttingPatterns() {
        let facts: [(predicate: String, value: String, unitId: UnitIdentifier)] = [
            (predicate: "crossCuttingPatterns", value: "patterns: [AIProviderProtocol(5), DatabaseProtocol(4)], threshold: 3",
             unitId: UnitIdentifier(rawValue: 1)),
        ]
        let props = ReasoningEngineSupport.parseSystemProperties(from: facts)
        #expect(props.crossCuttingPatterns?.count == 2)
        #expect(props.crossCuttingPatterns?[0].name == "AIProviderProtocol")
        #expect(props.crossCuttingPatterns?[0].referenceCount == 5)
        #expect(props.crossCuttingPatterns?[1].name == "DatabaseProtocol")
        #expect(props.crossCuttingThreshold == 3)
    }

    @Test("Parses technology distribution")
    func parseTechnologyDistribution() {
        let facts: [(predicate: String, value: String, unitId: UnitIdentifier)] = [
            (predicate: "technologyDistribution", value: "languages: [Swift(92.5), Python(7.5)], primary: Swift",
             unitId: UnitIdentifier(rawValue: 1)),
        ]
        let props = ReasoningEngineSupport.parseSystemProperties(from: facts)
        #expect(props.languages?.count == 2)
        #expect(props.languages?[0].name == "Swift")
        #expect(props.languages?[0].percentage == 92.5)
        #expect(props.primaryLanguage == "Swift")
    }

    @Test("Parses module interaction map")
    func parseModuleInteractionMap() {
        let facts: [(predicate: String, value: String, unitId: UnitIdentifier)] = [
            (predicate: "moduleInteractionMap",
             value: "edges: [Application->Domain(calls:25, conformsTo:3, inherits:0)]",
             unitId: UnitIdentifier(rawValue: 1)),
        ]
        let props = ReasoningEngineSupport.parseSystemProperties(from: facts)
        #expect(props.moduleInteractions?.count == 1)
        #expect(props.moduleInteractions?[0].source == "Application")
        #expect(props.moduleInteractions?[0].target == "Domain")
        #expect(props.moduleInteractions?[0].calls == 25)
        #expect(props.moduleInteractions?[0].conformsTo == 3)
    }

    @Test("Unknown predicates are ignored")
    func unknownPredicatesIgnored() {
        let facts: [(predicate: String, value: String, unitId: UnitIdentifier)] = [
            (predicate: "someFuturePredicate", value: "whatever", unitId: UnitIdentifier(rawValue: 1)),
        ]
        let props = ReasoningEngineSupport.parseSystemProperties(from: facts)
        #expect(props.architectureStyle == nil)
        #expect(props.moduleCount == nil)
    }
}

// MARK: - Suite 2: System Observation Extraction

@Suite("M11-S2 System Observation Extraction")
struct SystemObservationExtractionTests {

    @Test("Extracts observations from layered system")
    func extractLayeredSystem() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits()
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations != nil)
        #expect(observations?.systemName == "Decode")
        #expect(observations?.entityName == "SessionResolver")
        #expect(observations?.architecture != nil)
        #expect(observations?.architecture?.value == "layered")
        #expect(observations?.dependencies != nil)
        #expect(observations?.scale != nil)
    }

    @Test("Returns nil when no system entity exists")
    func noSystemEntity() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class")),
        ]
        let contextUnits = codeUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: knowledge.entityNames
        )

        #expect(observations == nil)
    }

    @Test("Returns nil for trivial system with 1 module")
    func trivialSystemSuppressed() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits(moduleCount: 1)
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations == nil)
    }

    @Test("Suppresses architecture when style is unknown")
    func unknownArchitectureSuppressed() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits(architectureStyle: "unknown", architectureEvidence: "")
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        // Scale and dependencies may still produce observations even without architecture.
        if let obs = observations {
            #expect(obs.architecture == nil)
        }
    }

    @Test("Extracts cross-cutting observation with entity awareness")
    func crossCuttingEntityAwareness() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "AIProviderProtocol", predicateName: "kind", value: .string("protocol")),
        ]
        let systemUnits = makeSystemUnits() + [makeCrossCuttingUnit()]
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations?.crossCutting != nil)
        #expect(observations?.crossCutting?.interpretation.contains("cross-cutting concern") == true)
    }

    @Test("Extracts technology observation for multi-language system")
    func technologyMultiLanguage() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits() + [makeTechnologyUnit()]
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations?.technologies != nil)
        #expect(observations?.technologies?.value.contains("Swift") == true)
        #expect(observations?.technologies?.interpretation == "Swift-dominant system")
    }

    @Test("Suppresses technology for single-language system")
    func singleLanguageSuppressed() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits() + [
            makeTechnologyUnit(languages: "[Swift(100.0)]", primary: "Swift"),
        ]
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        // technologies requires >= 2 languages
        #expect(observations?.technologies == nil)
    }
}

// MARK: - Suite 3: Observation Builders

@Suite("M11-S3 Observation Builders")
struct SystemObservationBuildersTests {

    @Test("Architecture observation uses evidence text")
    func architectureUsesEvidence() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits(
            architectureStyle: "layered",
            architectureEvidence: "Presentation → Application → Domain → Infrastructure"
        )
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations?.architecture?.value == "layered")
        #expect(observations?.architecture?.interpretation.contains("Presentation") == true)
    }

    @Test("Dependency observation reports clean flow when no violations")
    func cleanDependencies() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits(hasCycles: false, violationCount: 0, totalEdges: 52)
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations?.dependencies?.interpretation.contains("clean dependency flow") == true)
    }

    @Test("Dependency observation flags cycles")
    func dependencyCyclesDetected() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits(hasCycles: true, violationCount: 3, totalEdges: 52)
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations?.dependencies?.interpretation.contains("cycles") == true)
    }

    @Test("Scale observation classifies small system")
    func scaleSmallSystem() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits(moduleCount: 3, totalFileCount: 15, totalEntityCount: 40)
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations?.scale?.interpretation == "small system")
    }

    @Test("Scale observation classifies large system")
    func scaleLargeSystem() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits(moduleCount: 20, totalFileCount: 500, totalEntityCount: 2000)
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations?.scale?.interpretation == "large-scale system")
    }

    @Test("Interaction observation filters to entity module")
    func interactionFiltersToModule() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits() + [makeInteractionUnit()]
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames,
            moduleName: "Application"
        )

        #expect(observations?.interactions != nil)
        #expect(observations?.interactions?.value.contains("Application") == true)
    }

    @Test("Interaction observation returns nil when no module name")
    func interactionNilWithoutModuleName() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits() + [makeInteractionUnit()]
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames,
            moduleName: nil
        )

        #expect(observations?.interactions == nil)
    }

    @Test("Dependency observation suppressed with fewer than 2 layers")
    func dependencySuppressedFewLayers() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits(layerCount: 1)
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations?.dependencies == nil)
    }
}

// MARK: - Suite 4: Guidance Generation

@Suite("M11-S4 System Guidance Generation")
struct SystemGuidanceGenerationTests {

    @Test("Guidance includes architecture framing with module context")
    func guidanceWithArchitectureAndModule() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits()
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames,
            moduleName: "Application"
        )

        #expect(observations?.guidance.contains("layered") == true)
    }

    @Test("Guidance mentions cycle concern when cycles present")
    func guidanceWithCycles() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits(hasCycles: true, violationCount: 3)
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations?.guidance.contains("cycles") == true)
    }

    @Test("Guidance emphasizes cross-module impact for cross-cutting entity")
    func guidanceCrossCuttingEntity() {
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "AIProviderProtocol", predicateName: "kind", value: .string("protocol")),
        ]
        let systemUnits = makeSystemUnits() + [makeCrossCuttingUnit()]
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        #expect(observations?.guidance.contains("cross-module impact") == true)
    }

    @Test("Guidance falls back to generic when all specific observations suppressed")
    func guidanceFallbackGeneric() {
        // System with unknown architecture and only 1 layer — most observations suppressed.
        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits(architectureStyle: "unknown", layerCount: 1)
        let allUnits = codeUnits + systemUnits
        let contextUnits = allUnits.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        let observations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        // Scale observation should still be present (8 modules), so observations not nil.
        if let obs = observations {
            #expect(obs.guidance.contains("system context") == true || obs.guidance.contains("layered") == false)
        }
    }
}

// MARK: - Suite 5: Prompt Formatting

@Suite("M11-S5 Prompt Formatting")
struct SystemPromptFormattingTests {

    @Test("formatForPrompt includes system name and observations")
    func formatForPromptIncludesContent() {
        let obs = SystemObservations(
            systemName: "Decode",
            entityName: "SessionResolver",
            architecture: SystemObservations.ArchitectureObservation(
                value: "layered",
                interpretation: "4 layers"
            ),
            dependencies: SystemObservations.DependencyObservation(
                value: "4 layers, no cycles, 0 violations",
                interpretation: "clean dependency flow across 52 edges"
            ),
            scale: SystemObservations.ScaleObservation(
                value: "8 modules, 120 files, 450 entities",
                interpretation: "medium-scale system"
            ),
            crossCutting: nil,
            interactions: nil,
            technologies: nil,
            guidance: "Frame this entity within a layered system architecture."
        )

        let output = obs.formatForPrompt()

        #expect(output.contains("SYSTEM OBSERVATIONS — SessionResolver"))
        #expect(output.contains("system:       Decode"))
        #expect(output.contains("architecture: layered — 4 layers"))
        #expect(output.contains("dependencies: 4 layers, no cycles, 0 violations"))
        #expect(output.contains("scale:        8 modules, 120 files, 450 entities"))
        #expect(output.contains("guidance:     Frame this entity"))
    }

    @Test("formatForPrompt respects prioritized ordering")
    func formatWithPrioritizedOrder() {
        let obs = SystemObservations(
            systemName: "Decode",
            entityName: "MyClass",
            architecture: SystemObservations.ArchitectureObservation(
                value: "layered", interpretation: "4 layers"
            ),
            dependencies: SystemObservations.DependencyObservation(
                value: "4 layers, no cycles, 0 violations",
                interpretation: "clean"
            ),
            scale: SystemObservations.ScaleObservation(
                value: "8 modules", interpretation: "medium"
            ),
            crossCutting: nil,
            interactions: nil,
            technologies: nil,
            guidance: "Test."
        )

        let reordered = obs.formatForPrompt(prioritizedOrder: [.scale, .dependencies, .architecture])

        // Scale should appear before architecture in the output.
        let scaleRange = reordered.range(of: "scale:")!
        let archRange = reordered.range(of: "architecture:")!
        #expect(scaleRange.lowerBound < archRange.lowerBound)
    }

    @Test("formatForContextSummary produces compact line")
    func formatForContextSummary() {
        let obs = SystemObservations(
            systemName: "Decode",
            entityName: "MyClass",
            architecture: SystemObservations.ArchitectureObservation(
                value: "layered", interpretation: "4 layers"
            ),
            dependencies: nil,
            scale: SystemObservations.ScaleObservation(
                value: "8 modules", interpretation: "medium"
            ),
            crossCutting: nil,
            interactions: nil,
            technologies: nil,
            guidance: "Test."
        )

        let summary = obs.formatForContextSummary()

        #expect(summary == "System: Decode, layered, 8 modules.")
    }

    @Test("systemPromptInstruction mentions SYSTEM OBSERVATIONS")
    func systemPromptInstructionContent() {
        #expect(SystemObservations.systemPromptInstruction.contains("SYSTEM OBSERVATIONS"))
    }

    @Test("followUpContextInstruction mentions system-level")
    func followUpContextInstructionContent() {
        #expect(SystemObservations.followUpContextInstruction.contains("system-level"))
    }
}

// MARK: - Suite 6: filterProjectEntities

@Suite("M11-S6 filterProjectEntities")
struct FilterProjectEntitiesTests {

    @Test("Removes both module: and system: entities")
    func filtersBothModuleAndSystem() {
        let units: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class")),
            makeUnit(id: 2, entityName: "module:Application", predicateName: "kind", value: .string("module"), tier: .t1),
            makeUnit(id: 3, entityName: "system:Decode", predicateName: "kind", value: .string("system"), tier: .t1),
        ]
        let contextUnits = units.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        #expect(filtered.entityNames == ["SessionResolver"])
        #expect(filtered.entityFacts.keys.contains("module:Application") == false)
        #expect(filtered.entityFacts.keys.contains("system:Decode") == false)
        #expect(filtered.entityFacts.keys.contains("SessionResolver") == true)
    }

    @Test("Preserves all entities when no module/system present")
    func preservesNonProjectEntities() {
        let units: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "ClassA", predicateName: "kind", value: .string("class")),
            makeUnit(id: 2, entityName: "ClassB", predicateName: "kind", value: .string("struct")),
        ]
        let contextUnits = units.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        #expect(filtered.entityNames.count == 2)
        #expect(filtered.entityNames.contains("ClassA"))
        #expect(filtered.entityNames.contains("ClassB"))
    }

    @Test("Returns empty when only project entities exist")
    func emptyWhenOnlyProjectEntities() {
        let units: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "module:App", predicateName: "kind", value: .string("module"), tier: .t1),
            makeUnit(id: 2, entityName: "system:Decode", predicateName: "kind", value: .string("system"), tier: .t1),
        ]
        let contextUnits = units.map { contextUnit(from: $0) }
        let knowledge = ReasoningEngineSupport.extractKnowledge(from: contextUnits)
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        #expect(filtered.entityNames.isEmpty)
        #expect(filtered.entityFacts.isEmpty)
    }
}

// MARK: - Suite 7: Question-Aware Ordering

@Suite("M11-S7 Question-Aware Ordering")
struct QuestionAwareOrderingTests {

    @Test("Why questions prioritize architecture and dependencies")
    func whyQuestionPriority() {
        let order = ReasoningEngineSupport.questionAwareOrder(questionHint: "Why does this exist?")

        #expect(order != nil)
        #expect(order?[0] == .architecture)
        #expect(order?[1] == .dependencies)
    }

    @Test("Impact questions prioritize dependencies and cross-cutting")
    func impactQuestionPriority() {
        let order = ReasoningEngineSupport.questionAwareOrder(questionHint: "What's the impact of changing this?")

        #expect(order != nil)
        #expect(order?[0] == .dependencies)
        #expect(order?[1] == .crossCutting)
    }

    @Test("Overview questions prioritize architecture and scale")
    func overviewQuestionPriority() {
        let order = ReasoningEngineSupport.questionAwareOrder(questionHint: "Give me an overview of this system")

        #expect(order != nil)
        #expect(order?[0] == .architecture)
        #expect(order?[1] == .scale)
        #expect(order?[2] == .technologies)
    }

    @Test("Narrow syntax questions return nil ordering")
    func narrowQuestionNil() {
        let order = ReasoningEngineSupport.questionAwareOrder(questionHint: "What does this line do?")
        #expect(order == nil)
    }

    @Test("Generic questions return nil ordering (default)")
    func genericQuestionDefault() {
        let order = ReasoningEngineSupport.questionAwareOrder(questionHint: "How does this work?")
        #expect(order == nil)
    }

    @Test("Nil question returns nil ordering")
    func nilQuestion() {
        let order = ReasoningEngineSupport.questionAwareOrder(questionHint: nil)
        #expect(order == nil)
    }

    @Test("Empty question returns nil ordering")
    func emptyQuestion() {
        let order = ReasoningEngineSupport.questionAwareOrder(questionHint: "")
        #expect(order == nil)
    }

    @Test("shouldSuppressSystemForNarrowQuestion detects syntax questions")
    func suppressForSyntax() {
        #expect(ReasoningEngineSupport.shouldSuppressSystemForNarrowQuestion(questionHint: "What does this line do?") == true)
        #expect(ReasoningEngineSupport.shouldSuppressSystemForNarrowQuestion(questionHint: "What is the syntax here?") == true)
        #expect(ReasoningEngineSupport.shouldSuppressSystemForNarrowQuestion(questionHint: "just this function") == true)
    }

    @Test("shouldSuppressSystemForNarrowQuestion does not suppress broad questions")
    func noSuppressForBroadQuestions() {
        #expect(ReasoningEngineSupport.shouldSuppressSystemForNarrowQuestion(questionHint: "Why does this exist?") == false)
        #expect(ReasoningEngineSupport.shouldSuppressSystemForNarrowQuestion(questionHint: "What's the architecture?") == false)
        #expect(ReasoningEngineSupport.shouldSuppressSystemForNarrowQuestion(questionHint: nil) == false)
    }
}

// MARK: - Suite 8: Engine Integration

@Suite("M11-S8 Engine Integration")
struct SystemObservationEngineIntegrationTests {

    @Test("ExplainReasoningEngine includes system observations in prompt")
    func explainEngineIncludesSystem() async throws {
        let mockProvider = M11MockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class")),
            makeUnit(id: 2, entityName: "SessionResolver", predicateName: "language", value: .string("swift")),
        ]
        let systemUnits = makeSystemUnits()
        let frame = makeFrame(units: codeUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(output.content == "Test explanation.")
        #expect(mockProvider.lastUserContent.contains("SYSTEM OBSERVATIONS"))
    }

    @Test("ExplainReasoningEngine system prompt includes system instruction when observations present")
    func explainSystemPromptIncludesInstruction() async throws {
        let mockProvider = M11MockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits()
        let frame = makeFrame(units: codeUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(mockProvider.lastSystemPrompt.contains("SYSTEM OBSERVATIONS"))
    }

    @Test("ExplainReasoningEngine omits system observations when no system entity")
    func explainEngineOmitsSystemWithout() async throws {
        let mockProvider = M11MockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class")),
        ]
        let frame = makeFrame(units: codeUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(!mockProvider.lastUserContent.contains("SYSTEM OBSERVATIONS"))
        #expect(!mockProvider.lastSystemPrompt.contains("SYSTEM OBSERVATIONS"))
    }

    @Test("ExplainReasoningEngine does not include raw system entity facts in prompt")
    func explainNoRawSystemFacts() async throws {
        let mockProvider = M11MockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits()
        let frame = makeFrame(units: codeUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        // Raw system entity should not appear in entities section.
        #expect(!mockProvider.lastUserContent.contains("### system:Decode"))
    }

    @Test("FollowUpReasoningEngine initial invocation includes system observations")
    func followUpEngineInitialIncludesSystem() async throws {
        let mockProvider = M11MockAIProvider()
        let engine = FollowUpReasoningEngine(aiProvider: { mockProvider })

        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits()
        let frame = makeFrame(units: codeUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("followup"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        #expect(output.content == "Test explanation.")
        #expect(mockProvider.lastUserContent.contains("SYSTEM OBSERVATIONS"))
        #expect(output.conversationState != nil)
    }

    @Test("FollowUpReasoningEngine context summary includes system info")
    func followUpContextSummaryIncludesSystem() async throws {
        let mockProvider = M11MockAIProvider()
        let engine = FollowUpReasoningEngine(aiProvider: { mockProvider })

        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "MyClass", predicateName: "kind", value: .string("class")),
        ]
        let systemUnits = makeSystemUnits()
        let frame = makeFrame(units: codeUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("followup"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        if let stateData = output.conversationState?.data {
            let state = try JSONDecoder().decode(FollowUpReasoningEngine.FollowUpState.self, from: stateData)
            #expect(state.contextSummary.contains("System:"))
        } else {
            Issue.record("Expected conversation state to be non-nil")
        }
    }

    @Test("System observations appear before module observations in prompt")
    func systemBeforeModuleInPrompt() async throws {
        let mockProvider = M11MockAIProvider()
        let engine = ExplainReasoningEngine(aiProvider: { mockProvider })

        let codeUnits: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "SessionResolver", predicateName: "kind", value: .string("class")),
            makeUnit(id: 2, entityName: "SessionResolver", predicateName: "language", value: .string("swift")),
        ]

        let moduleEntity = "module:Application"
        let moduleUnits: [AtomicUnit] = [
            makeUnit(id: 100, entityName: moduleEntity, predicateName: "kind",
                     predicateDomain: "structure", value: .string("module"), tier: .t1),
            makeUnit(id: 101, entityName: moduleEntity, predicateName: "fileCount",
                     predicateDomain: "composition", value: .integer(5), tier: .t1),
            makeUnit(id: 102, entityName: moduleEntity, predicateName: "moduleRole",
                     predicateDomain: "emergence", value: .string("provider"), tier: .t1),
            makeUnit(id: 103, entityName: moduleEntity, predicateName: "publicInterface",
                     predicateDomain: "emergence",
                     value: .structured([
                        "count": .integer(2),
                        "entities": .string("SessionResolver"),
                     ]), tier: .t1),
        ]

        let systemUnits = makeSystemUnits(startId: 200)
        let frame = makeFrame(units: codeUnits + moduleUnits + systemUnits)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        _ = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)

        // Verify ordering: SYSTEM OBSERVATIONS before MODULE OBSERVATIONS.
        if let systemPos = mockProvider.lastUserContent.range(of: "SYSTEM OBSERVATIONS"),
           let modulePos = mockProvider.lastUserContent.range(of: "MODULE OBSERVATIONS") {
            #expect(systemPos.lowerBound < modulePos.lowerBound)
        }
        #expect(mockProvider.lastUserContent.contains("SYSTEM OBSERVATIONS"))
    }
}

// MARK: - Mock AI Provider

/// Class-based mock for testing reasoning engine integration.
/// Uses `@unchecked Sendable` to allow mutable state capture in async contexts.
private final class M11MockAIProvider: AIProviderProtocol, @unchecked Sendable {
    var lastSystemPrompt: String = ""
    var lastUserContent: String = ""
    var completionResponse: String = "Test explanation."

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
