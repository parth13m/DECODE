// CrossFileResolutionPassTests.swift — DecodeTests
// M1: Tests for cross-file entity resolution composition pass.

import Testing
import Foundation
@testable import Decode
import ProducerRuntime
import DIRCore

// MARK: - Test Helpers

/// Creates an AtomicUnit representing a "kind" predicate for an entity,
/// grounded to a specific file path.
private func makeKindUnit(
    id: UInt64,
    qualifiedName: String,
    filePath: String,
    kind: String = "class"
) -> AtomicUnit {
    let version = VersionStamp(
        singleSource: ContentHash(bytes: Array(repeating: 0, count: 32))
    )
    return AtomicUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .entity(EntityReference(qualifiedName: qualifiedName)),
        predicate: PredicateIdentifier(name: "kind", domain: "structure"),
        value: .string(kind),
        tier: .t0,
        provenance: ProvenanceRecord(
            producer: "test-frontend",
            method: .extraction,
            timestamp: Date(timeIntervalSince1970: 0),
            inputUnitIds: []
        ),
        confidence: .deterministic,
        grounding: .direct(SourcePosition(
            filePath: filePath,
            startLine: 1,
            endLine: 10,
            fileVersion: ContentHash(bytes: Array(repeating: 0, count: 32))
        )),
        version: version
    )
}

/// Creates an AtomicUnit representing a relationship predicate.
private func makeRelationshipUnit(
    id: UInt64,
    sourceName: String,
    targetName: String,
    filePath: String,
    relationship: String = "calls"
) -> AtomicUnit {
    let version = VersionStamp(
        singleSource: ContentHash(bytes: Array(repeating: 0, count: 32))
    )
    return AtomicUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .pair(EntityPair(
            source: EntityReference(qualifiedName: sourceName),
            target: EntityReference(qualifiedName: targetName)
        )),
        predicate: PredicateIdentifier(name: relationship, domain: "relationship"),
        value: .boolean(true),
        tier: .t0,
        provenance: ProvenanceRecord(
            producer: "test-frontend",
            method: .extraction,
            timestamp: Date(timeIntervalSince1970: 0),
            inputUnitIds: []
        ),
        confidence: .deterministic,
        grounding: .direct(SourcePosition(
            filePath: filePath,
            startLine: 5,
            endLine: 5,
            fileVersion: ContentHash(bytes: Array(repeating: 0, count: 32))
        )),
        version: version
    )
}

/// Invokes the CrossFileResolutionPass handler with the given input set.
private func executeHandler(inputSet: [AtomicUnit]) async throws -> [PassOutput] {
    let scopeWindow = ScopeWindow(
        entities: Set(inputSet.compactMap { unit -> EntityReference? in
            if case .entity(let ref) = unit.subject { return ref }
            return nil
        }),
        identifier: ScopeWindowIdentifier("system")
    )
    return try await CrossFileResolutionPass.handler(
        inputSet,
        scopeWindow,
        CrossFileResolutionPass.identity,
        OutputContract(
            predicates: CrossFileResolutionPass.outputPredicates,
            tierRange: .t1 ... .t1
        ),
        nil
    )
}

/// Filters outputs for a specific predicate name and domain.
private func outputsFor(
    _ name: String,
    domain: String,
    in outputs: [PassOutput]
) -> [PassOutput] {
    outputs.filter { $0.predicate == PredicateIdentifier(name: name, domain: domain) }
}

/// Extracts the target qualified name from a paired PassOutput.
private func targetName(_ output: PassOutput) -> String? {
    if case .pair(let pair) = output.subject {
        return pair.target.qualifiedName
    }
    return nil
}

/// Extracts the source qualified name from a paired PassOutput.
private func sourceName(_ output: PassOutput) -> String? {
    if case .pair(let pair) = output.subject {
        return pair.source.qualifiedName
    }
    return nil
}

// MARK: - Contract Tests

@Suite("CrossFileResolutionPass Contract")
struct CFRPContractTests {

    @Test("Identity has correct identifier and version")
    func identity() {
        let id = CrossFileResolutionPass.identity
        #expect(id.identifier.name == "cross-file-resolution-pass")
        #expect(id.version.major == 1)
        #expect(id.version.minor == 0)
    }

    @Test("Contract declares perSystem scope")
    func scopeIsPerSystem() {
        #expect(CrossFileResolutionPass.contract.scope == .perSystem)
    }

    @Test("Contract is not a composition pass")
    func isNotComposition() {
        #expect(CrossFileResolutionPass.contract.isComposition == false)
    }

    @Test("Contract is idempotent")
    func isIdempotent() {
        #expect(CrossFileResolutionPass.contract.isIdempotent == true)
    }

    @Test("Contract depends on both frontends")
    func dependsOnFrontends() {
        let deps = CrossFileResolutionPass.contract.dependencies
        #expect(deps.contains(ProducerIdentifier(name: "swift-syntax-frontend")))
        #expect(deps.contains(ProducerIdentifier(name: "tree-sitter-frontend")))
    }

    @Test("Contract reads T0 input only")
    func inputTiers() {
        #expect(CrossFileResolutionPass.contract.inputContract.tiers == [.t0])
    }

    @Test("Contract outputs T1 only")
    func outputTiers() {
        #expect(CrossFileResolutionPass.contract.outputContract.tierRange == .t1 ... .t1)
    }

    @Test("Input predicates include kind and three relationship types")
    func inputPredicates() {
        let preds = CrossFileResolutionPass.inputPredicates
        #expect(preds.contains(PredicateIdentifier(name: "kind", domain: "structure")))
        #expect(preds.contains(PredicateIdentifier(name: "calls", domain: "relationship")))
        #expect(preds.contains(PredicateIdentifier(name: "conformsTo", domain: "relationship")))
        #expect(preds.contains(PredicateIdentifier(name: "inherits", domain: "relationship")))
        // owns is NOT included
        #expect(!preds.contains(PredicateIdentifier(name: "owns", domain: "relationship")))
    }

    @Test("Output predicates are the same three relationship types")
    func outputPredicates() {
        let preds = CrossFileResolutionPass.outputPredicates
        #expect(preds.count == 3)
        #expect(preds.contains(PredicateIdentifier(name: "calls", domain: "relationship")))
        #expect(preds.contains(PredicateIdentifier(name: "conformsTo", domain: "relationship")))
        #expect(preds.contains(PredicateIdentifier(name: "inherits", domain: "relationship")))
    }

    @Test("Execution strategy is deterministic")
    func executionStrategy() {
        #expect(CrossFileResolutionPass.contract.executionStrategy == .deterministic)
    }
}

// MARK: - Cross-File Resolution Tests

@Suite("CrossFileResolutionPass Cross-File Resolution")
struct CrossFileResolutionTests {

    @Test("Resolves a calls relationship to a unique cross-file entity")
    func resolveUniqueCrossFileCalls() async throws {
        // File A: ClassA calls "doWork"
        // File B: ClassB defines "doWork"
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "ClassA", filePath: "/src/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "ClassB", filePath: "/src/B.swift"),
            makeKindUnit(id: 3, qualifiedName: "ClassB.doWork", filePath: "/src/B.swift", kind: "method"),
            makeRelationshipUnit(id: 10, sourceName: "ClassA", targetName: "doWork", filePath: "/src/A.swift", relationship: "calls"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        #expect(outputs.count == 1)
        #expect(outputs[0].predicate == PredicateIdentifier(name: "calls", domain: "relationship"))
        #expect(targetName(outputs[0]) == "ClassB.doWork")
        #expect(sourceName(outputs[0]) == "ClassA")
        #expect(outputs[0].tier == .t1)
        #expect(outputs[0].confidence == .high)
        if case .boolean(let v) = outputs[0].value {
            #expect(v == true)
        } else {
            Issue.record("Expected boolean value")
        }
    }

    @Test("Resolves a conformsTo relationship to a cross-file protocol")
    func resolveCrossFileConformsTo() async throws {
        // File A: ClassA conforms to "Printable"
        // File B: protocol Printable
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "ClassA", filePath: "/src/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "Printable", filePath: "/src/B.swift", kind: "protocol"),
            makeRelationshipUnit(id: 10, sourceName: "ClassA", targetName: "Printable", filePath: "/src/A.swift", relationship: "conformsTo"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        #expect(outputs.count == 1)
        #expect(outputs[0].predicate == PredicateIdentifier(name: "conformsTo", domain: "relationship"))
        #expect(targetName(outputs[0]) == "Printable")
        #expect(outputs[0].confidence == .high)
    }

    @Test("Resolves an inherits relationship to a cross-file class")
    func resolveCrossFileInherits() async throws {
        // File A: SubClass inherits "BaseClass"
        // File B: class BaseClass
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "SubClass", filePath: "/src/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "BaseClass", filePath: "/src/B.swift"),
            makeRelationshipUnit(id: 10, sourceName: "SubClass", targetName: "BaseClass", filePath: "/src/A.swift", relationship: "inherits"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        #expect(outputs.count == 1)
        #expect(outputs[0].predicate == PredicateIdentifier(name: "inherits", domain: "relationship"))
        #expect(targetName(outputs[0]) == "BaseClass")
        #expect(outputs[0].confidence == .high)
    }

    @Test("Resolves nested entity target by simple name")
    func resolveNestedEntityTarget() async throws {
        // File A: calls "parse"
        // File B: Parser.parse (method)
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "Consumer", filePath: "/src/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "Parser", filePath: "/src/B.swift"),
            makeKindUnit(id: 3, qualifiedName: "Parser.parse", filePath: "/src/B.swift", kind: "method"),
            makeRelationshipUnit(id: 10, sourceName: "Consumer", targetName: "parse", filePath: "/src/A.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        #expect(outputs.count == 1)
        #expect(targetName(outputs[0]) == "Parser.parse")
        #expect(outputs[0].confidence == .high)
    }

    @Test("Multiple relationships across multiple files")
    func multipleRelationshipsMultipleFiles() async throws {
        let units: [AtomicUnit] = [
            // Three files with entities
            makeKindUnit(id: 1, qualifiedName: "Controller", filePath: "/src/Controller.swift"),
            makeKindUnit(id: 2, qualifiedName: "Service", filePath: "/src/Service.swift"),
            makeKindUnit(id: 3, qualifiedName: "Service.execute", filePath: "/src/Service.swift", kind: "method"),
            makeKindUnit(id: 4, qualifiedName: "Repository", filePath: "/src/Repository.swift"),
            makeKindUnit(id: 5, qualifiedName: "Repository.fetch", filePath: "/src/Repository.swift", kind: "method"),
            // Controller calls Service.execute and Repository.fetch
            makeRelationshipUnit(id: 10, sourceName: "Controller", targetName: "execute", filePath: "/src/Controller.swift"),
            makeRelationshipUnit(id: 11, sourceName: "Controller", targetName: "fetch", filePath: "/src/Controller.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        #expect(outputs.count == 2)
        let targets = Set(outputs.compactMap { targetName($0) })
        #expect(targets.contains("Service.execute"))
        #expect(targets.contains("Repository.fetch"))
    }
}

// MARK: - Same-File Skip Tests

@Suite("CrossFileResolutionPass Same-File Skipping")
struct SameFileSkipTests {

    @Test("Does not resolve relationships within the same file")
    func skipSameFileRelationship() async throws {
        // Both source and target are in the same file
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "ClassA", filePath: "/src/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "ClassA.helper", filePath: "/src/A.swift", kind: "method"),
            makeRelationshipUnit(id: 10, sourceName: "ClassA", targetName: "helper", filePath: "/src/A.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        #expect(outputs.isEmpty)
    }

    @Test("Resolves only cross-file when target exists in both same and other file")
    func resolveCrossFileOnlyWhenBothExist() async throws {
        // "helper" exists in both file A (same as source) and file B (cross-file)
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "ClassA", filePath: "/src/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "ClassA.helper", filePath: "/src/A.swift", kind: "method"),
            makeKindUnit(id: 3, qualifiedName: "ClassB.helper", filePath: "/src/B.swift", kind: "method"),
            makeRelationshipUnit(id: 10, sourceName: "ClassA", targetName: "helper", filePath: "/src/A.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        #expect(outputs.count == 1)
        #expect(targetName(outputs[0]) == "ClassB.helper")
        #expect(outputs[0].confidence == .high)
    }
}

// MARK: - Owns Skip Tests

@Suite("CrossFileResolutionPass Owns Skipping")
struct OwnsSkipTests {

    @Test("Does not resolve owns relationships")
    func skipOwnsRelationship() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "ClassA", filePath: "/src/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "ClassB", filePath: "/src/B.swift"),
            makeRelationshipUnit(id: 10, sourceName: "ClassA", targetName: "ClassB", filePath: "/src/A.swift", relationship: "owns"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        #expect(outputs.isEmpty)
    }
}

// MARK: - Ambiguity Tests

@Suite("CrossFileResolutionPass Ambiguity Handling")
struct AmbiguityTests {

    @Test("Two cross-file candidates produce low confidence outputs")
    func twoCandidatesLowConfidence() async throws {
        // "process" exists in two different cross-file locations
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "Caller", filePath: "/src/Caller.swift"),
            makeKindUnit(id: 2, qualifiedName: "ServiceA.process", filePath: "/src/ServiceA.swift", kind: "method"),
            makeKindUnit(id: 3, qualifiedName: "ServiceB.process", filePath: "/src/ServiceB.swift", kind: "method"),
            makeRelationshipUnit(id: 10, sourceName: "Caller", targetName: "process", filePath: "/src/Caller.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        #expect(outputs.count == 2)
        for output in outputs {
            #expect(output.confidence == .low)
            #expect(output.tier == .t1)
        }
        let targets = Set(outputs.compactMap { targetName($0) })
        #expect(targets.contains("ServiceA.process"))
        #expect(targets.contains("ServiceB.process"))
    }

    @Test("Three cross-file candidates produce low confidence outputs")
    func threeCandidatesLowConfidence() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "Caller", filePath: "/src/Caller.swift"),
            makeKindUnit(id: 2, qualifiedName: "A.configure", filePath: "/src/A.swift", kind: "method"),
            makeKindUnit(id: 3, qualifiedName: "B.configure", filePath: "/src/B.swift", kind: "method"),
            makeKindUnit(id: 4, qualifiedName: "C.configure", filePath: "/src/C.swift", kind: "method"),
            makeRelationshipUnit(id: 10, sourceName: "Caller", targetName: "configure", filePath: "/src/Caller.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        #expect(outputs.count == 3)
        for output in outputs {
            #expect(output.confidence == .low)
        }
    }

    @Test("Four or more cross-file candidates are skipped")
    func fourCandidatesSkipped() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "Caller", filePath: "/src/Caller.swift"),
            makeKindUnit(id: 2, qualifiedName: "A.init", filePath: "/src/A.swift", kind: "method"),
            makeKindUnit(id: 3, qualifiedName: "B.init", filePath: "/src/B.swift", kind: "method"),
            makeKindUnit(id: 4, qualifiedName: "C.init", filePath: "/src/C.swift", kind: "method"),
            makeKindUnit(id: 5, qualifiedName: "D.init", filePath: "/src/D.swift", kind: "method"),
            makeRelationshipUnit(id: 10, sourceName: "Caller", targetName: "init", filePath: "/src/Caller.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        #expect(outputs.isEmpty)
    }

    @Test("Exactly at threshold: three candidates produces output, four does not")
    func thresholdBoundary() async throws {
        // Three candidates — should produce output
        let unitsThree: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "Caller", filePath: "/src/Caller.swift"),
            makeKindUnit(id: 2, qualifiedName: "X.run", filePath: "/src/X.swift", kind: "method"),
            makeKindUnit(id: 3, qualifiedName: "Y.run", filePath: "/src/Y.swift", kind: "method"),
            makeKindUnit(id: 4, qualifiedName: "Z.run", filePath: "/src/Z.swift", kind: "method"),
            makeRelationshipUnit(id: 10, sourceName: "Caller", targetName: "run", filePath: "/src/Caller.swift"),
        ]

        let outputsThree = try await executeHandler(inputSet: unitsThree)
        #expect(outputsThree.count == 3)

        // Four candidates — should skip
        var unitsFour = unitsThree
        unitsFour.insert(
            makeKindUnit(id: 5, qualifiedName: "W.run", filePath: "/src/W.swift", kind: "method"),
            at: 4
        )

        let outputsFour = try await executeHandler(inputSet: unitsFour)
        #expect(outputsFour.isEmpty)
    }
}

// MARK: - Confidence Tests

@Suite("CrossFileResolutionPass Confidence")
struct ConfidenceTests {

    @Test("Unique cross-file match produces high confidence")
    func uniqueMatchHighConfidence() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "ClassA", filePath: "/src/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "ClassB.uniqueMethod", filePath: "/src/B.swift", kind: "method"),
            makeRelationshipUnit(id: 10, sourceName: "ClassA", targetName: "uniqueMethod", filePath: "/src/A.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        #expect(outputs.count == 1)
        #expect(outputs[0].confidence == .high)
    }

    @Test("Ambiguous match produces low confidence")
    func ambiguousMatchLowConfidence() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "ClassA", filePath: "/src/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "ClassB.start", filePath: "/src/B.swift", kind: "method"),
            makeKindUnit(id: 3, qualifiedName: "ClassC.start", filePath: "/src/C.swift", kind: "method"),
            makeRelationshipUnit(id: 10, sourceName: "ClassA", targetName: "start", filePath: "/src/A.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        #expect(outputs.count == 2)
        for output in outputs {
            #expect(output.confidence == .low)
        }
    }
}

// MARK: - Grounding Tests

@Suite("CrossFileResolutionPass Grounding")
struct CFRPGroundingTests {

    @Test("Grounding refs include T0 relationship unit and target kind unit")
    func groundingRefsContainBothSources() async throws {
        let relUnitId: UInt64 = 10
        let targetKindUnitId: UInt64 = 2

        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "Caller", filePath: "/src/A.swift"),
            makeKindUnit(id: targetKindUnitId, qualifiedName: "Target", filePath: "/src/B.swift"),
            makeRelationshipUnit(id: relUnitId, sourceName: "Caller", targetName: "Target", filePath: "/src/A.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        #expect(outputs.count == 1)
        let grounding = outputs[0].groundingRefs
        #expect(grounding.count == 2)
        #expect(grounding.contains(UnitIdentifier(rawValue: relUnitId)))
        #expect(grounding.contains(UnitIdentifier(rawValue: targetKindUnitId)))
    }
}

// MARK: - Tier Tests

@Suite("CrossFileResolutionPass Tier")
struct TierTests {

    @Test("All outputs are T1")
    func allOutputsAreT1() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "ClassA", filePath: "/src/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "ClassB", filePath: "/src/B.swift"),
            makeKindUnit(id: 3, qualifiedName: "ClassB.method", filePath: "/src/B.swift", kind: "method"),
            makeRelationshipUnit(id: 10, sourceName: "ClassA", targetName: "ClassB", filePath: "/src/A.swift", relationship: "conformsTo"),
            makeRelationshipUnit(id: 11, sourceName: "ClassA", targetName: "method", filePath: "/src/A.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        #expect(!outputs.isEmpty)
        for output in outputs {
            #expect(output.tier == .t1)
        }
    }

    @Test("All outputs use boolean true value")
    func allOutputsUseBooleanTrue() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "A", filePath: "/src/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "B", filePath: "/src/B.swift"),
            makeRelationshipUnit(id: 10, sourceName: "A", targetName: "B", filePath: "/src/A.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        #expect(outputs.count == 1)
        if case .boolean(let v) = outputs[0].value {
            #expect(v == true)
        } else {
            Issue.record("Expected boolean value")
        }
    }
}

// MARK: - Predicate Preservation Tests

@Suite("CrossFileResolutionPass Predicate Preservation")
struct PredicatePreservationTests {

    @Test("calls relationship produces calls output predicate")
    func callsPreserved() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "A", filePath: "/src/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "B", filePath: "/src/B.swift"),
            makeRelationshipUnit(id: 10, sourceName: "A", targetName: "B", filePath: "/src/A.swift", relationship: "calls"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        #expect(outputs[0].predicate == PredicateIdentifier(name: "calls", domain: "relationship"))
    }

    @Test("conformsTo relationship produces conformsTo output predicate")
    func conformsToPreserved() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "A", filePath: "/src/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "B", filePath: "/src/B.swift", kind: "protocol"),
            makeRelationshipUnit(id: 10, sourceName: "A", targetName: "B", filePath: "/src/A.swift", relationship: "conformsTo"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        #expect(outputs[0].predicate == PredicateIdentifier(name: "conformsTo", domain: "relationship"))
    }

    @Test("inherits relationship produces inherits output predicate")
    func inheritsPreserved() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "A", filePath: "/src/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "B", filePath: "/src/B.swift"),
            makeRelationshipUnit(id: 10, sourceName: "A", targetName: "B", filePath: "/src/A.swift", relationship: "inherits"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        #expect(outputs[0].predicate == PredicateIdentifier(name: "inherits", domain: "relationship"))
    }
}

// MARK: - Edge Case Tests

@Suite("CrossFileResolutionPass Edge Cases")
struct CFRPEdgeCaseTests {

    @Test("Empty input produces no output")
    func emptyInput() async throws {
        let outputs = try await executeHandler(inputSet: [])
        #expect(outputs.isEmpty)
    }

    @Test("Entities only, no relationships, produces no output")
    func entitiesOnlyNoRelationships() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "ClassA", filePath: "/src/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "ClassB", filePath: "/src/B.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        #expect(outputs.isEmpty)
    }

    @Test("Relationships only, no entities in registry, produces no output")
    func relationshipsOnlyNoEntities() async throws {
        let units: [AtomicUnit] = [
            makeRelationshipUnit(id: 10, sourceName: "A", targetName: "B", filePath: "/src/A.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        #expect(outputs.isEmpty)
    }

    @Test("Target not found in any file produces no output")
    func targetNotFound() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "ClassA", filePath: "/src/A.swift"),
            makeRelationshipUnit(id: 10, sourceName: "ClassA", targetName: "nonExistent", filePath: "/src/A.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        #expect(outputs.isEmpty)
    }

    @Test("File entities (file: prefix) are excluded from registry")
    func fileEntitiesExcluded() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/src/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "ClassA", filePath: "/src/A.swift"),
            makeRelationshipUnit(id: 10, sourceName: "ClassA", targetName: "file:B.swift", filePath: "/src/A.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        #expect(outputs.isEmpty)
    }

    @Test("Source entity file resolved from unit grounding when not in registry")
    func sourceFileFromGrounding() async throws {
        // Source entity "UnknownCaller" is not in the kind:structure units,
        // but the relationship unit has grounding with file path.
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "Target", filePath: "/src/B.swift"),
            makeRelationshipUnit(id: 10, sourceName: "UnknownCaller", targetName: "Target", filePath: "/src/A.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        #expect(outputs.count == 1)
        #expect(targetName(outputs[0]) == "Target")
    }
}

// MARK: - Idempotency Tests

@Suite("CrossFileResolutionPass Idempotency")
struct CFRPIdempotencyTests {

    @Test("Running the handler twice produces identical output")
    func idempotent() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "ClassA", filePath: "/src/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "ClassB", filePath: "/src/B.swift"),
            makeKindUnit(id: 3, qualifiedName: "ClassB.work", filePath: "/src/B.swift", kind: "method"),
            makeRelationshipUnit(id: 10, sourceName: "ClassA", targetName: "work", filePath: "/src/A.swift"),
            makeRelationshipUnit(id: 11, sourceName: "ClassA", targetName: "ClassB", filePath: "/src/A.swift", relationship: "conformsTo"),
        ]

        let outputs1 = try await executeHandler(inputSet: units)
        let outputs2 = try await executeHandler(inputSet: units)

        #expect(outputs1.count == outputs2.count)
        for (o1, o2) in zip(outputs1, outputs2) {
            #expect(o1.subject == o2.subject)
            #expect(o1.predicate == o2.predicate)
            #expect(o1.value == o2.value)
            #expect(o1.tier == o2.tier)
            #expect(o1.confidence == o2.confidence)
            #expect(o1.groundingRefs == o2.groundingRefs)
        }
    }
}

// MARK: - Simple Name Helper Tests

@Suite("CrossFileResolutionPass SimpleName Helper")
struct SimpleNameTests {

    @Test("Simple name from unqualified name returns same name")
    func unqualifiedName() {
        #expect(CrossFileResolutionPass.simpleName(from: "ClassName") == "ClassName")
    }

    @Test("Simple name from qualified name returns last component")
    func qualifiedName() {
        #expect(CrossFileResolutionPass.simpleName(from: "ClassName.methodName") == "methodName")
    }

    @Test("Simple name from deeply nested name returns last component")
    func deeplyNested() {
        #expect(CrossFileResolutionPass.simpleName(from: "A.B.C") == "C")
    }

    @Test("Simple name from empty string returns empty string")
    func emptyString() {
        #expect(CrossFileResolutionPass.simpleName(from: "") == "")
    }
}
