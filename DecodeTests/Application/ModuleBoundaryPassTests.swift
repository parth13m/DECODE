// ModuleBoundaryPassTests.swift — DecodeTests
// PI-001: Tests for directory-based module boundary detection composition pass.
// PI-002: Tests for deterministic module enrichment (emergent properties).

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

/// Creates an AtomicUnit representing an "imports" predicate for a file entity.
private func makeImportUnit(
    id: UInt64,
    qualifiedName: String,
    filePath: String,
    importValue: String
) -> AtomicUnit {
    let version = VersionStamp(
        singleSource: ContentHash(bytes: Array(repeating: 0, count: 32))
    )
    return AtomicUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .entity(EntityReference(qualifiedName: qualifiedName)),
        predicate: PredicateIdentifier(name: "imports", domain: "dependency"),
        value: .string(importValue),
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
            endLine: 1,
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

/// Invokes the ModuleBoundaryPass handler with the given input set.
private func executeHandler(inputSet: [AtomicUnit]) async throws -> [PassOutput] {
    let scopeWindow = ScopeWindow(
        entities: Set(inputSet.compactMap { unit -> EntityReference? in
            if case .entity(let ref) = unit.subject { return ref }
            return nil
        }),
        identifier: ScopeWindowIdentifier("system")
    )
    return try await ModuleBoundaryPass.handler(
        inputSet,
        scopeWindow,
        ModuleBoundaryPass.identity,
        OutputContract(
            predicates: ModuleBoundaryPass.outputPredicates,
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

/// Extracts the integer value from a PassOutput, or nil.
private func intValue(_ output: PassOutput) -> Int64? {
    if case .integer(let v) = output.value { return v }
    return nil
}

// MARK: - PI-001 Contract Tests

@Suite("ModuleBoundaryPass Contract")
struct ContractTests {

    @Test("Identity has correct identifier and version")
    func identity() {
        let id = ModuleBoundaryPass.identity
        #expect(id.identifier.name == "module-boundary-pass")
        #expect(id.version.major == 1)
        #expect(id.version.minor == 1)
    }

    @Test("Contract declares perSystem scope")
    func scopeIsPerSystem() {
        #expect(ModuleBoundaryPass.contract.scope == .perSystem)
    }

    @Test("Contract is a composition pass")
    func isComposition() {
        #expect(ModuleBoundaryPass.contract.isComposition == true)
    }

    @Test("Contract is deterministic")
    func isDeterministic() {
        #expect(ModuleBoundaryPass.contract.executionStrategy == .deterministic)
    }

    @Test("Contract is idempotent")
    func isIdempotent() {
        #expect(ModuleBoundaryPass.contract.isIdempotent == true)
    }

    @Test("Contract reads T0 predicates including relationships and imports")
    func inputContract() {
        let input = ModuleBoundaryPass.contract.inputContract
        #expect(input.predicates.contains(PredicateIdentifier(name: "kind", domain: "structure")))
        #expect(input.predicates.contains(PredicateIdentifier(name: "imports", domain: "dependency")))
        #expect(input.predicates.contains(PredicateIdentifier(name: "calls", domain: "relationship")))
        #expect(input.predicates.contains(PredicateIdentifier(name: "conformsTo", domain: "relationship")))
        #expect(input.predicates.contains(PredicateIdentifier(name: "inherits", domain: "relationship")))
        #expect(input.predicates.contains(PredicateIdentifier(name: "owns", domain: "relationship")))
        #expect(input.tiers.contains(.t0))
    }

    @Test("Contract produces T1 output")
    func outputTier() {
        let output = ModuleBoundaryPass.contract.outputContract
        #expect(output.tierRange == .t1 ... .t1)
    }

    @Test("Contract declares PI-001 output predicates")
    func pi001OutputPredicates() {
        let preds = ModuleBoundaryPass.contract.outputContract.predicates
        #expect(preds.contains(PredicateIdentifier(name: "kind", domain: "structure")))
        #expect(preds.contains(PredicateIdentifier(name: "name", domain: "structure")))
        #expect(preds.contains(PredicateIdentifier(name: "path", domain: "structure")))
        #expect(preds.contains(PredicateIdentifier(name: "fileCount", domain: "composition")))
        #expect(preds.contains(PredicateIdentifier(name: "contains", domain: "containment")))
    }

    @Test("Contract declares PI-002 enrichment predicates")
    func pi002OutputPredicates() {
        let preds = ModuleBoundaryPass.contract.outputContract.predicates
        #expect(preds.contains(PredicateIdentifier(name: "entityCount", domain: "composition")))
        #expect(preds.contains(PredicateIdentifier(name: "typeCount", domain: "composition")))
        #expect(preds.contains(PredicateIdentifier(name: "functionCount", domain: "composition")))
        #expect(preds.contains(PredicateIdentifier(name: "importCount", domain: "composition")))
        #expect(preds.contains(PredicateIdentifier(name: "relationshipCount", domain: "composition")))
        #expect(preds.contains(PredicateIdentifier(name: "languageDistribution", domain: "composition")))
        #expect(preds.contains(PredicateIdentifier(name: "entityKindDistribution", domain: "composition")))
        #expect(preds.contains(PredicateIdentifier(name: "externalImports", domain: "composition")))
    }

    @Test("Contract depends on both frontends")
    func dependencies() {
        let deps = ModuleBoundaryPass.contract.dependencies
        #expect(deps.contains(ProducerIdentifier(name: "swift-syntax-frontend")))
        #expect(deps.contains(ProducerIdentifier(name: "tree-sitter-frontend")))
    }
}

// MARK: - PI-001 Handler Tests (Regression)

@Suite("ModuleBoundaryPass Handler — PI-001 Regression")
struct PI001HandlerTests {

    @Test("Empty input produces no output")
    func emptyInput() async throws {
        let outputs = try await executeHandler(inputSet: [])
        #expect(outputs.isEmpty)
    }

    @Test("Single file entity creates one module")
    func singleFileEntity() async throws {
        let unit = makeKindUnit(
            id: 1,
            qualifiedName: "file:AppDelegate.swift",
            filePath: "/project/Sources/App/AppDelegate.swift"
        )
        let outputs = try await executeHandler(inputSet: [unit])

        let kindOutputs = outputsFor("kind", domain: "structure", in: outputs)
        #expect(kindOutputs.count == 1)
        if case .entity(let ref) = kindOutputs.first?.subject {
            #expect(ref.qualifiedName == "module:App")
        }
        #expect(kindOutputs.first?.value == .string("module"))
        #expect(kindOutputs.first?.tier == .t1)
    }

    @Test("Multiple files in same directory create one module")
    func sameDirectoryGrouping() async throws {
        let units = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/Sources/App/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "file:B.swift", filePath: "/project/Sources/App/B.swift"),
            makeKindUnit(id: 3, qualifiedName: "file:C.swift", filePath: "/project/Sources/App/C.swift"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        let kindOutputs = outputsFor("kind", domain: "structure", in: outputs)
        #expect(kindOutputs.count == 1)

        let fileCountOutputs = outputsFor("fileCount", domain: "composition", in: outputs)
        #expect(fileCountOutputs.count == 1)
        #expect(fileCountOutputs.first?.value == .integer(3))
    }

    @Test("Files in different directories create separate modules")
    func differentDirectories() async throws {
        let units = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/Sources/App/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "file:B.swift", filePath: "/project/Sources/Domain/B.swift"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        let kindOutputs = outputsFor("kind", domain: "structure", in: outputs)
        #expect(kindOutputs.count == 2)

        let moduleNames = kindOutputs.compactMap { output -> String? in
            if case .entity(let ref) = output.subject {
                return ref.qualifiedName
            }
            return nil
        }
        #expect(moduleNames.contains("module:App"))
        #expect(moduleNames.contains("module:Domain"))
    }

    @Test("Module entity has correct name predicate")
    func nameOutput() async throws {
        let unit = makeKindUnit(
            id: 1,
            qualifiedName: "file:Test.swift",
            filePath: "/project/Sources/Models/Test.swift"
        )
        let outputs = try await executeHandler(inputSet: [unit])

        let nameOutputs = outputsFor("name", domain: "structure", in: outputs)
        #expect(nameOutputs.count == 1)
        #expect(nameOutputs.first?.value == .string("Models"))
    }

    @Test("Module entity has correct path predicate")
    func pathOutput() async throws {
        let unit = makeKindUnit(
            id: 1,
            qualifiedName: "file:Test.swift",
            filePath: "/project/Sources/Models/Test.swift"
        )
        let outputs = try await executeHandler(inputSet: [unit])

        let pathOutputs = outputsFor("path", domain: "structure", in: outputs)
        #expect(pathOutputs.count == 1)
        #expect(pathOutputs.first?.value == .string("/project/Sources/Models"))
    }

    @Test("Containment relationships are created for each file")
    func containmentRelationships() async throws {
        let units = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/Sources/App/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "file:B.swift", filePath: "/project/Sources/App/B.swift"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        let containsOutputs = outputsFor("contains", domain: "containment", in: outputs)
        #expect(containsOutputs.count == 2)

        for output in containsOutputs {
            #expect(output.value == .boolean(true))
            #expect(output.tier == .t1)
        }
    }

    @Test("Non-file entities contribute to module via grounding chain")
    func nonFileEntityGrouping() async throws {
        let units = [
            makeKindUnit(id: 1, qualifiedName: "MyClass", filePath: "/project/Sources/App/MyClass.swift", kind: "class"),
            makeKindUnit(id: 2, qualifiedName: "MyStruct", filePath: "/project/Sources/App/MyStruct.swift", kind: "struct"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        let kindOutputs = outputsFor("kind", domain: "structure", in: outputs)
        #expect(kindOutputs.count == 1)
        if case .entity(let ref) = kindOutputs.first?.subject {
            #expect(ref.qualifiedName == "module:App")
        }
    }

    @Test("Inactive units are skipped")
    func inactiveUnitsSkipped() async throws {
        let version = VersionStamp(
            singleSource: ContentHash(bytes: Array(repeating: 0, count: 32))
        )
        var unit = AtomicUnit(
            id: UnitIdentifier(rawValue: 1),
            subject: .entity(EntityReference(qualifiedName: "file:A.swift")),
            predicate: PredicateIdentifier(name: "kind", domain: "structure"),
            value: .string("class"),
            tier: .t0,
            provenance: ProvenanceRecord(
                producer: "test-frontend",
                method: .extraction,
                timestamp: Date(timeIntervalSince1970: 0),
                inputUnitIds: []
            ),
            confidence: .deterministic,
            grounding: .direct(SourcePosition(
                filePath: "/project/Sources/App/A.swift",
                startLine: 1,
                endLine: 10,
                fileVersion: ContentHash(bytes: Array(repeating: 0, count: 32))
            )),
            version: version
        )
        unit.invalidate(metadata: InvalidationMetadata(
            epoch: Epoch(value: 1),
            reason: .sourceChanged
        ))

        let outputs = try await executeHandler(inputSet: [unit])
        #expect(outputs.isEmpty)
    }

    @Test("All outputs have high confidence")
    func outputConfidence() async throws {
        let unit = makeKindUnit(
            id: 1,
            qualifiedName: "file:Test.swift",
            filePath: "/project/Sources/App/Test.swift"
        )
        let outputs = try await executeHandler(inputSet: [unit])

        for output in outputs {
            #expect(output.confidence == .high)
        }
    }

    @Test("All outputs are T1 tier")
    func outputTier() async throws {
        let unit = makeKindUnit(
            id: 1,
            qualifiedName: "file:Test.swift",
            filePath: "/project/Sources/App/Test.swift"
        )
        let outputs = try await executeHandler(inputSet: [unit])

        for output in outputs {
            #expect(output.tier == .t1)
        }
    }

    @Test("Mixed file and non-file entities in same directory deduplicate")
    func mixedEntityDeduplication() async throws {
        let units = [
            makeKindUnit(id: 1, qualifiedName: "file:MyClass.swift", filePath: "/project/Sources/App/MyClass.swift"),
            makeKindUnit(id: 2, qualifiedName: "MyClass", filePath: "/project/Sources/App/MyClass.swift", kind: "class"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        let kindOutputs = outputsFor("kind", domain: "structure", in: outputs)
        #expect(kindOutputs.count == 1)
    }
}

// MARK: - PI-002 Enrichment Tests

@Suite("ModuleBoundaryPass Enrichment — Entity Counts")
struct EntityCountTests {

    @Test("entityCount counts non-file entities")
    func entityCount() async throws {
        let units = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "MyClass", filePath: "/project/App/A.swift", kind: "class"),
            makeKindUnit(id: 3, qualifiedName: "MyClass.doSomething", filePath: "/project/App/A.swift", kind: "method"),
            makeKindUnit(id: 4, qualifiedName: "MyStruct", filePath: "/project/App/A.swift", kind: "struct"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        let entityCountOutputs = outputsFor("entityCount", domain: "composition", in: outputs)
        #expect(entityCountOutputs.count == 1)
        #expect(intValue(entityCountOutputs.first!) == 3) // MyClass, doSomething, MyStruct
    }

    @Test("typeCount counts class, struct, enum, protocol entities")
    func typeCount() async throws {
        let units = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "MyClass", filePath: "/project/App/A.swift", kind: "class"),
            makeKindUnit(id: 3, qualifiedName: "MyStruct", filePath: "/project/App/A.swift", kind: "struct"),
            makeKindUnit(id: 4, qualifiedName: "MyEnum", filePath: "/project/App/A.swift", kind: "enum"),
            makeKindUnit(id: 5, qualifiedName: "MyProtocol", filePath: "/project/App/A.swift", kind: "protocol"),
            makeKindUnit(id: 6, qualifiedName: "myFunction", filePath: "/project/App/A.swift", kind: "function"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        let typeCountOutputs = outputsFor("typeCount", domain: "composition", in: outputs)
        #expect(typeCountOutputs.count == 1)
        #expect(intValue(typeCountOutputs.first!) == 4) // class, struct, enum, protocol
    }

    @Test("functionCount counts function and method entities")
    func functionCount() async throws {
        let units = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "doSomething", filePath: "/project/App/A.swift", kind: "function"),
            makeKindUnit(id: 3, qualifiedName: "MyClass.process", filePath: "/project/App/A.swift", kind: "method"),
            makeKindUnit(id: 4, qualifiedName: "MyClass", filePath: "/project/App/A.swift", kind: "class"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        let funcCountOutputs = outputsFor("functionCount", domain: "composition", in: outputs)
        #expect(funcCountOutputs.count == 1)
        #expect(intValue(funcCountOutputs.first!) == 2) // function + method
    }

    @Test("Module with only file entities has zero entity/type/function counts")
    func fileOnlyModule() async throws {
        let units = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "file:B.swift", filePath: "/project/App/B.swift"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        #expect(intValue(outputsFor("entityCount", domain: "composition", in: outputs).first!) == 0)
        #expect(intValue(outputsFor("typeCount", domain: "composition", in: outputs).first!) == 0)
        #expect(intValue(outputsFor("functionCount", domain: "composition", in: outputs).first!) == 0)
    }
}

@Suite("ModuleBoundaryPass Enrichment — Import Tracking")
struct ImportTrackingTests {

    @Test("importCount counts unique imports across files")
    func importCount() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift"),
            makeImportUnit(id: 2, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift", importValue: "Foundation"),
            makeImportUnit(id: 3, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift", importValue: "SwiftUI"),
            makeKindUnit(id: 4, qualifiedName: "file:B.swift", filePath: "/project/App/B.swift"),
            makeImportUnit(id: 5, qualifiedName: "file:B.swift", filePath: "/project/App/B.swift", importValue: "Foundation"),
            makeImportUnit(id: 6, qualifiedName: "file:B.swift", filePath: "/project/App/B.swift", importValue: "Combine"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        let importCountOutputs = outputsFor("importCount", domain: "composition", in: outputs)
        #expect(importCountOutputs.count == 1)
        #expect(intValue(importCountOutputs.first!) == 3) // Foundation (deduped), SwiftUI, Combine
    }

    @Test("externalImports emits one predicate per unique import")
    func externalImports() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift"),
            makeImportUnit(id: 2, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift", importValue: "Foundation"),
            makeImportUnit(id: 3, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift", importValue: "SwiftUI"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        let importOutputs = outputsFor("externalImports", domain: "composition", in: outputs)
        #expect(importOutputs.count == 2)

        let importValues = importOutputs.compactMap { output -> String? in
            if case .string(let v) = output.value { return v }
            return nil
        }
        #expect(importValues.contains("Foundation"))
        #expect(importValues.contains("SwiftUI"))
    }

    @Test("Duplicate imports across files are deduplicated")
    func deduplicatedImports() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift"),
            makeImportUnit(id: 2, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift", importValue: "Foundation"),
            makeKindUnit(id: 3, qualifiedName: "file:B.swift", filePath: "/project/App/B.swift"),
            makeImportUnit(id: 4, qualifiedName: "file:B.swift", filePath: "/project/App/B.swift", importValue: "Foundation"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        let importOutputs = outputsFor("externalImports", domain: "composition", in: outputs)
        #expect(importOutputs.count == 1)
        #expect(importOutputs.first?.value == .string("Foundation"))
    }

    @Test("Module with no imports has zero importCount and no externalImports")
    func noImports() async throws {
        let units = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        #expect(intValue(outputsFor("importCount", domain: "composition", in: outputs).first!) == 0)
        #expect(outputsFor("externalImports", domain: "composition", in: outputs).isEmpty)
    }
}

@Suite("ModuleBoundaryPass Enrichment — Relationship Counting")
struct RelationshipCountTests {

    @Test("relationshipCount counts all relationship predicates in module")
    func relationshipCount() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "MyClass", filePath: "/project/App/A.swift", kind: "class"),
            makeRelationshipUnit(id: 2, sourceName: "MyClass", targetName: "doWork", filePath: "/project/App/A.swift", relationship: "calls"),
            makeRelationshipUnit(id: 3, sourceName: "MyClass", targetName: "Sendable", filePath: "/project/App/A.swift", relationship: "conformsTo"),
            makeRelationshipUnit(id: 4, sourceName: "MyClass", targetName: "Base", filePath: "/project/App/A.swift", relationship: "inherits"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        let relCountOutputs = outputsFor("relationshipCount", domain: "composition", in: outputs)
        #expect(relCountOutputs.count == 1)
        #expect(intValue(relCountOutputs.first!) == 3) // calls + conformsTo + inherits
    }

    @Test("owns relationships are counted")
    func ownsRelationshipCounted() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "MyClass", filePath: "/project/App/A.swift", kind: "class"),
            makeRelationshipUnit(id: 2, sourceName: "MyClass", targetName: "name", filePath: "/project/App/A.swift", relationship: "owns"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        let relCountOutputs = outputsFor("relationshipCount", domain: "composition", in: outputs)
        #expect(intValue(relCountOutputs.first!) == 1)
    }

    @Test("Module with no relationships has zero relationshipCount")
    func noRelationships() async throws {
        let units = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        #expect(intValue(outputsFor("relationshipCount", domain: "composition", in: outputs).first!) == 0)
    }
}

@Suite("ModuleBoundaryPass Enrichment — Language Distribution")
struct LanguageDistributionTests {

    @Test("Language distribution counts file extensions")
    func languageDistribution() async throws {
        let units = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "file:B.swift", filePath: "/project/App/B.swift"),
            makeKindUnit(id: 3, qualifiedName: "file:C.py", filePath: "/project/App/C.py"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        let langOutputs = outputsFor("languageDistribution", domain: "composition", in: outputs)
        #expect(langOutputs.count == 1)

        if case .structured(let map) = langOutputs.first?.value {
            #expect(map["swift"] == .integer(2))
            #expect(map["py"] == .integer(1))
        } else {
            Issue.record("Expected structured value for languageDistribution")
        }
    }

    @Test("Single-language module has one-entry distribution")
    func singleLanguage() async throws {
        let units = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "file:B.swift", filePath: "/project/App/B.swift"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        let langOutputs = outputsFor("languageDistribution", domain: "composition", in: outputs)
        if case .structured(let map) = langOutputs.first?.value {
            #expect(map.count == 1)
            #expect(map["swift"] == .integer(2))
        } else {
            Issue.record("Expected structured value for languageDistribution")
        }
    }
}

@Suite("ModuleBoundaryPass Enrichment — Entity Kind Distribution")
struct EntityKindDistributionTests {

    @Test("Entity kind distribution tracks all entity kinds")
    func kindDistribution() async throws {
        let units = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "MyClass", filePath: "/project/App/A.swift", kind: "class"),
            makeKindUnit(id: 3, qualifiedName: "MyStruct", filePath: "/project/App/A.swift", kind: "struct"),
            makeKindUnit(id: 4, qualifiedName: "doWork", filePath: "/project/App/A.swift", kind: "function"),
            makeKindUnit(id: 5, qualifiedName: "MyClass.process", filePath: "/project/App/A.swift", kind: "method"),
            makeKindUnit(id: 6, qualifiedName: "AnotherClass", filePath: "/project/App/A.swift", kind: "class"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        let kindDistOutputs = outputsFor("entityKindDistribution", domain: "composition", in: outputs)
        #expect(kindDistOutputs.count == 1)

        if case .structured(let map) = kindDistOutputs.first?.value {
            #expect(map["class"] == .integer(2))
            #expect(map["struct"] == .integer(1))
            #expect(map["function"] == .integer(1))
            #expect(map["method"] == .integer(1))
        } else {
            Issue.record("Expected structured value for entityKindDistribution")
        }
    }

    @Test("Module with no code entities has no entityKindDistribution")
    func noEntitiesNoDistribution() async throws {
        let units = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        let kindDistOutputs = outputsFor("entityKindDistribution", domain: "composition", in: outputs)
        #expect(kindDistOutputs.isEmpty) // No distribution emitted for empty
    }
}

// MARK: - PI-002 Idempotency and Stability Tests

@Suite("ModuleBoundaryPass Idempotency")
struct IdempotencyTests {

    @Test("Same input produces identical output on repeated execution")
    func idempotentExecution() async throws {
        let units: [AtomicUnit] = [
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "MyClass", filePath: "/project/App/A.swift", kind: "class"),
            makeImportUnit(id: 3, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift", importValue: "Foundation"),
            makeRelationshipUnit(id: 4, sourceName: "MyClass", targetName: "doWork", filePath: "/project/App/A.swift"),
        ]

        let outputs1 = try await executeHandler(inputSet: units)
        let outputs2 = try await executeHandler(inputSet: units)

        // Same count of outputs
        #expect(outputs1.count == outputs2.count)

        // Same predicate distribution
        for predName in ["kind", "name", "path", "fileCount", "entityCount", "typeCount",
                         "functionCount", "importCount", "relationshipCount"] {
            let domain = (predName == "kind" || predName == "name" || predName == "path")
                ? "structure" : "composition"
            let count1 = outputsFor(predName, domain: domain, in: outputs1).count
            let count2 = outputsFor(predName, domain: domain, in: outputs2).count
            #expect(count1 == count2, "Mismatch for \(predName): \(count1) vs \(count2)")
        }
    }

    @Test("Output is deterministic regardless of input order")
    func orderIndependent() async throws {
        let unitA = makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift")
        let unitB = makeKindUnit(id: 2, qualifiedName: "file:B.swift", filePath: "/project/App/B.swift")

        let outputs1 = try await executeHandler(inputSet: [unitA, unitB])
        let outputs2 = try await executeHandler(inputSet: [unitB, unitA])

        // Same total output count
        #expect(outputs1.count == outputs2.count)

        // Same fileCount
        let fc1 = intValue(outputsFor("fileCount", domain: "composition", in: outputs1).first!)
        let fc2 = intValue(outputsFor("fileCount", domain: "composition", in: outputs2).first!)
        #expect(fc1 == fc2)
    }
}

// MARK: - PI-002 Multi-Module Tests

@Suite("ModuleBoundaryPass Multi-Module Enrichment")
struct MultiModuleTests {

    @Test("Each module gets independent enrichment properties")
    func independentEnrichment() async throws {
        let units: [AtomicUnit] = [
            // App module: 1 file, 2 entities, 1 import
            makeKindUnit(id: 1, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift"),
            makeKindUnit(id: 2, qualifiedName: "MyClass", filePath: "/project/App/A.swift", kind: "class"),
            makeKindUnit(id: 3, qualifiedName: "MyClass.run", filePath: "/project/App/A.swift", kind: "method"),
            makeImportUnit(id: 4, qualifiedName: "file:A.swift", filePath: "/project/App/A.swift", importValue: "Foundation"),
            // Domain module: 1 file, 1 entity, 2 imports
            makeKindUnit(id: 5, qualifiedName: "file:B.swift", filePath: "/project/Domain/B.swift"),
            makeKindUnit(id: 6, qualifiedName: "MyProtocol", filePath: "/project/Domain/B.swift", kind: "protocol"),
            makeImportUnit(id: 7, qualifiedName: "file:B.swift", filePath: "/project/Domain/B.swift", importValue: "Foundation"),
            makeImportUnit(id: 8, qualifiedName: "file:B.swift", filePath: "/project/Domain/B.swift", importValue: "Combine"),
        ]
        let outputs = try await executeHandler(inputSet: units)

        // Two modules created
        let kindOutputs = outputsFor("kind", domain: "structure", in: outputs)
        #expect(kindOutputs.count == 2)

        // Find App module's entityCount
        let entityCountOutputs = outputsFor("entityCount", domain: "composition", in: outputs)
        #expect(entityCountOutputs.count == 2)

        // Find the entity counts — they should be 2 (App) and 1 (Domain)
        let entityCounts = entityCountOutputs.compactMap { intValue($0) }.sorted()
        #expect(entityCounts == [1, 2])

        // Find import counts — 1 (App: Foundation) and 2 (Domain: Foundation, Combine)
        let importCountOutputs = outputsFor("importCount", domain: "composition", in: outputs)
        let importCounts = importCountOutputs.compactMap { intValue($0) }.sorted()
        #expect(importCounts == [1, 2])
    }
}

// MARK: - Helper Tests

@Suite("ModuleBoundaryPass Helpers")
struct HelperTests {

    @Test("directoryPath extracts parent directory")
    func basicDirectoryPath() {
        let result = ModuleBoundaryPass.directoryPath(from: "/project/Sources/App/File.swift")
        #expect(result == "/project/Sources/App")
    }

    @Test("directoryPath handles root-level file")
    func rootLevelFile() {
        let result = ModuleBoundaryPass.directoryPath(from: "/File.swift")
        #expect(result == "/")
    }

    @Test("directoryPath handles deeply nested path")
    func deeplyNestedPath() {
        let result = ModuleBoundaryPass.directoryPath(from: "/a/b/c/d/e/f.swift")
        #expect(result == "/a/b/c/d/e")
    }
}
