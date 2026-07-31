// SystemCompositionPassTests.swift — DecodeTests
// M8: Tests for system entity creation via module → system composition.

import Testing
import Foundation
@testable import Decode
import ProducerRuntime
import DIRCore

// MARK: - Test Helpers

/// Creates a T1 AtomicUnit representing a module "kind:structure" predicate.
private func makeModuleKindUnit(
    id: UInt64,
    moduleName: String
) -> AtomicUnit {
    let version = VersionStamp(
        singleSource: ContentHash(bytes: Array(repeating: 0, count: 32))
    )
    return AtomicUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .entity(EntityReference(qualifiedName: "module:\(moduleName)")),
        predicate: PredicateIdentifier(name: "kind", domain: "structure"),
        value: .string("module"),
        tier: .t1,
        provenance: ProvenanceRecord(
            producer: "module-boundary-pass",
            method: .derivation,
            timestamp: Date(timeIntervalSince1970: 0)
        ),
        confidence: .high,
        grounding: .derived([]),
        version: version
    )
}

/// Creates a T1 AtomicUnit representing a module metadata predicate.
private func makeModuleMetadataUnit(
    id: UInt64,
    moduleName: String,
    predicate: String,
    domain: String,
    value: TypedValue
) -> AtomicUnit {
    let version = VersionStamp(
        singleSource: ContentHash(bytes: Array(repeating: 0, count: 32))
    )
    return AtomicUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .entity(EntityReference(qualifiedName: "module:\(moduleName)")),
        predicate: PredicateIdentifier(name: predicate, domain: domain),
        value: value,
        tier: .t1,
        provenance: ProvenanceRecord(
            producer: "module-boundary-pass",
            method: .derivation,
            timestamp: Date(timeIntervalSince1970: 0)
        ),
        confidence: .high,
        grounding: .derived([]),
        version: version
    )
}

/// Invokes the SystemCompositionPass handler with the given input set.
private func executeHandler(inputSet: [AtomicUnit]) async throws -> [PassOutput] {
    let scopeWindow = ScopeWindow(
        entities: Set(inputSet.compactMap { unit -> EntityReference? in
            if case .entity(let ref) = unit.subject { return ref }
            return nil
        }),
        identifier: ScopeWindowIdentifier("system")
    )
    return try await SystemCompositionPass.handler(
        inputSet,
        scopeWindow,
        SystemCompositionPass.identity,
        OutputContract(
            predicates: SystemCompositionPass.outputPredicates,
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

/// Extracts the string value from a PassOutput, or nil.
private func stringValue(_ output: PassOutput) -> String? {
    if case .string(let v) = output.value { return v }
    return nil
}

/// Extracts the entity qualified name from a PassOutput's subject, or nil.
private func entityName(_ output: PassOutput) -> String? {
    if case .entity(let ref) = output.subject { return ref.qualifiedName }
    return nil
}

/// Creates a standard set of module units for a module with name, path, fileCount, entityCount.
private func makeModuleUnits(
    startId: UInt64,
    moduleName: String,
    modulePath: String,
    fileCount: Int64,
    entityCount: Int64,
    languageDistribution: [String: Int64]? = nil
) -> [AtomicUnit] {
    var units: [AtomicUnit] = []
    var nextId = startId

    units.append(makeModuleKindUnit(id: nextId, moduleName: moduleName))
    nextId += 1

    units.append(makeModuleMetadataUnit(
        id: nextId, moduleName: moduleName,
        predicate: "name", domain: "structure",
        value: .string(moduleName)
    ))
    nextId += 1

    units.append(makeModuleMetadataUnit(
        id: nextId, moduleName: moduleName,
        predicate: "path", domain: "structure",
        value: .string(modulePath)
    ))
    nextId += 1

    units.append(makeModuleMetadataUnit(
        id: nextId, moduleName: moduleName,
        predicate: "fileCount", domain: "composition",
        value: .integer(fileCount)
    ))
    nextId += 1

    units.append(makeModuleMetadataUnit(
        id: nextId, moduleName: moduleName,
        predicate: "entityCount", domain: "composition",
        value: .integer(entityCount)
    ))
    nextId += 1

    if let langDist = languageDistribution {
        var langMap: [String: TypedValue] = [:]
        for (ext, count) in langDist {
            langMap[ext] = .integer(count)
        }
        units.append(makeModuleMetadataUnit(
            id: nextId, moduleName: moduleName,
            predicate: "languageDistribution", domain: "composition",
            value: .structured(langMap)
        ))
    }

    return units
}

// MARK: - Contract Tests

@Suite("SystemCompositionPass Contract")
struct SCPContractTests {

    @Test("Identity has correct identifier and version")
    func identity() {
        let id = SystemCompositionPass.identity
        #expect(id.identifier.name == "system-composition-pass")
        #expect(id.version.major == 1)
        #expect(id.version.minor == 0)
    }

    @Test("Contract declares perSystem scope")
    func scopeIsPerSystem() {
        #expect(SystemCompositionPass.contract.scope == .perSystem)
    }

    @Test("Contract is a composition pass")
    func isComposition() {
        #expect(SystemCompositionPass.contract.isComposition == true)
    }

    @Test("Contract is deterministic")
    func isDeterministic() {
        #expect(SystemCompositionPass.contract.executionStrategy == .deterministic)
    }

    @Test("Contract is idempotent")
    func isIdempotent() {
        #expect(SystemCompositionPass.contract.isIdempotent == true)
    }

    @Test("Contract reads T1 predicates")
    func inputContract() {
        let input = SystemCompositionPass.contract.inputContract
        #expect(input.predicates.contains(PredicateIdentifier(name: "kind", domain: "structure")))
        #expect(input.predicates.contains(PredicateIdentifier(name: "name", domain: "structure")))
        #expect(input.predicates.contains(PredicateIdentifier(name: "path", domain: "structure")))
        #expect(input.predicates.contains(PredicateIdentifier(name: "fileCount", domain: "composition")))
        #expect(input.predicates.contains(PredicateIdentifier(name: "entityCount", domain: "composition")))
        #expect(input.predicates.contains(PredicateIdentifier(name: "languageDistribution", domain: "composition")))
        #expect(input.tiers.contains(.t1))
    }

    @Test("Contract produces T1 output")
    func outputTier() {
        let output = SystemCompositionPass.contract.outputContract
        #expect(output.tierRange == .t1 ... .t1)
    }

    @Test("Contract declares output predicates")
    func outputPredicates() {
        let preds = SystemCompositionPass.contract.outputContract.predicates
        #expect(preds.contains(PredicateIdentifier(name: "kind", domain: "structure")))
        #expect(preds.contains(PredicateIdentifier(name: "name", domain: "structure")))
        #expect(preds.contains(PredicateIdentifier(name: "path", domain: "structure")))
        #expect(preds.contains(PredicateIdentifier(name: "moduleCount", domain: "composition")))
        #expect(preds.contains(PredicateIdentifier(name: "totalFileCount", domain: "composition")))
        #expect(preds.contains(PredicateIdentifier(name: "totalEntityCount", domain: "composition")))
        #expect(preds.contains(PredicateIdentifier(name: "languageDistribution", domain: "composition")))
        #expect(preds.contains(PredicateIdentifier(name: "contains", domain: "containment")))
    }

    @Test("Contract depends on module-boundary-pass")
    func dependencies() {
        let deps = SystemCompositionPass.contract.dependencies
        #expect(deps.contains(ProducerIdentifier(name: "module-boundary-pass")))
        #expect(deps.count == 1)
    }
}

// MARK: - Empty and Minimal Input

@Suite("SystemCompositionPass — Empty and Minimal Input")
struct SCPMinimalTests {

    @Test("Empty input produces no output")
    func emptyInput() async throws {
        let outputs = try await executeHandler(inputSet: [])
        #expect(outputs.isEmpty)
    }

    @Test("No module entities produces no output")
    func noModuleEntities() async throws {
        // T1 units that are not modules (e.g., a file kind unit that happens to be T1).
        let version = VersionStamp(
            singleSource: ContentHash(bytes: Array(repeating: 0, count: 32))
        )
        let nonModuleUnit = AtomicUnit(
            id: UnitIdentifier(rawValue: 1),
            subject: .entity(EntityReference(qualifiedName: "file:Test.swift")),
            predicate: PredicateIdentifier(name: "kind", domain: "structure"),
            value: .string("file"),
            tier: .t1,
            provenance: ProvenanceRecord(
                producer: "test", method: .extraction,
                timestamp: Date(timeIntervalSince1970: 0)
            ),
            confidence: .high,
            grounding: .derived([]),
            version: version
        )
        let outputs = try await executeHandler(inputSet: [nonModuleUnit])
        #expect(outputs.isEmpty)
    }

    @Test("Single module creates system entity")
    func singleModule() async throws {
        let units = makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 5, entityCount: 20
        )
        let outputs = try await executeHandler(inputSet: units)

        // System kind exists.
        let kindOutputs = outputsFor("kind", domain: "structure", in: outputs)
        #expect(kindOutputs.count == 1)
        #expect(stringValue(kindOutputs.first!) == "system")

        // moduleCount = 1.
        let moduleCountOutputs = outputsFor("moduleCount", domain: "composition", in: outputs)
        #expect(moduleCountOutputs.count == 1)
        #expect(intValue(moduleCountOutputs.first!) == 1)

        // One contains relationship.
        let containsOutputs = outputsFor("contains", domain: "containment", in: outputs)
        #expect(containsOutputs.count == 1)
    }
}

// MARK: - Multi-Module Composition

@Suite("SystemCompositionPass — Multi-Module Composition")
struct SCPMultiModuleTests {

    @Test("Two modules create one system entity with correct module count")
    func twoModules() async throws {
        var units: [AtomicUnit] = []
        units += makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 3, entityCount: 10
        )
        units += makeModuleUnits(
            startId: 100, moduleName: "Domain",
            modulePath: "/project/Sources/Domain",
            fileCount: 5, entityCount: 15
        )

        let outputs = try await executeHandler(inputSet: units)

        let kindOutputs = outputsFor("kind", domain: "structure", in: outputs)
        #expect(kindOutputs.count == 1)
        #expect(stringValue(kindOutputs.first!) == "system")

        let moduleCountOutputs = outputsFor("moduleCount", domain: "composition", in: outputs)
        #expect(intValue(moduleCountOutputs.first!) == 2)

        let containsOutputs = outputsFor("contains", domain: "containment", in: outputs)
        #expect(containsOutputs.count == 2)
    }

    @Test("Five modules create one system with five containment relationships")
    func fiveModules() async throws {
        var units: [AtomicUnit] = []
        let moduleNames = ["App", "Domain", "Infrastructure", "Presentation", "Application"]
        for (i, name) in moduleNames.enumerated() {
            units += makeModuleUnits(
                startId: UInt64(i * 100 + 1), moduleName: name,
                modulePath: "/project/Decode/\(name)",
                fileCount: Int64(i + 2), entityCount: Int64((i + 1) * 5)
            )
        }

        let outputs = try await executeHandler(inputSet: units)

        let moduleCountOutputs = outputsFor("moduleCount", domain: "composition", in: outputs)
        #expect(intValue(moduleCountOutputs.first!) == 5)

        let containsOutputs = outputsFor("contains", domain: "containment", in: outputs)
        #expect(containsOutputs.count == 5)
    }

    @Test("System kind value is 'system'")
    func systemKindValue() async throws {
        let units = makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 3, entityCount: 10
        )
        let outputs = try await executeHandler(inputSet: units)

        let kindOutputs = outputsFor("kind", domain: "structure", in: outputs)
        #expect(kindOutputs.count == 1)
        #expect(stringValue(kindOutputs.first!) == "system")
    }

    @Test("System entity qualified name uses system: prefix")
    func systemEntityPrefix() async throws {
        let units = makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 3, entityCount: 10
        )
        let outputs = try await executeHandler(inputSet: units)

        let kindOutputs = outputsFor("kind", domain: "structure", in: outputs)
        let name = entityName(kindOutputs.first!)
        #expect(name?.hasPrefix("system:") == true)
    }

    @Test("Contains relationships target all modules")
    func containsTargetsAllModules() async throws {
        var units: [AtomicUnit] = []
        units += makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 3, entityCount: 10
        )
        units += makeModuleUnits(
            startId: 100, moduleName: "Domain",
            modulePath: "/project/Sources/Domain",
            fileCount: 5, entityCount: 15
        )

        let outputs = try await executeHandler(inputSet: units)

        let containsOutputs = outputsFor("contains", domain: "containment", in: outputs)
        let targetNames = containsOutputs.compactMap { output -> String? in
            if case .pair(let pair) = output.subject { return pair.target.qualifiedName }
            return nil
        }
        #expect(targetNames.contains("module:App"))
        #expect(targetNames.contains("module:Domain"))
    }

    @Test("Contains relationships source from system entity")
    func containsSourceIsSystem() async throws {
        let units = makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 3, entityCount: 10
        )
        let outputs = try await executeHandler(inputSet: units)

        let containsOutputs = outputsFor("contains", domain: "containment", in: outputs)
        for output in containsOutputs {
            if case .pair(let pair) = output.subject {
                #expect(pair.source.qualifiedName.hasPrefix("system:"))
            }
        }
    }
}

// MARK: - Structural Metadata Aggregation

@Suite("SystemCompositionPass — Metadata Aggregation")
struct SCPMetadataTests {

    @Test("totalFileCount sums module fileCounts")
    func totalFileCount() async throws {
        var units: [AtomicUnit] = []
        units += makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 3, entityCount: 10
        )
        units += makeModuleUnits(
            startId: 100, moduleName: "Domain",
            modulePath: "/project/Sources/Domain",
            fileCount: 7, entityCount: 15
        )

        let outputs = try await executeHandler(inputSet: units)

        let totalFileOutputs = outputsFor("totalFileCount", domain: "composition", in: outputs)
        #expect(totalFileOutputs.count == 1)
        #expect(intValue(totalFileOutputs.first!) == 10) // 3 + 7
    }

    @Test("totalEntityCount sums module entityCounts")
    func totalEntityCount() async throws {
        var units: [AtomicUnit] = []
        units += makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 3, entityCount: 10
        )
        units += makeModuleUnits(
            startId: 100, moduleName: "Domain",
            modulePath: "/project/Sources/Domain",
            fileCount: 7, entityCount: 25
        )

        let outputs = try await executeHandler(inputSet: units)

        let totalEntityOutputs = outputsFor("totalEntityCount", domain: "composition", in: outputs)
        #expect(totalEntityOutputs.count == 1)
        #expect(intValue(totalEntityOutputs.first!) == 35) // 10 + 25
    }

    @Test("moduleCount matches actual module count")
    func moduleCount() async throws {
        var units: [AtomicUnit] = []
        for i in 0..<4 {
            units += makeModuleUnits(
                startId: UInt64(i * 100 + 1), moduleName: "Module\(i)",
                modulePath: "/project/Sources/Module\(i)",
                fileCount: 2, entityCount: 5
            )
        }

        let outputs = try await executeHandler(inputSet: units)

        let moduleCountOutputs = outputsFor("moduleCount", domain: "composition", in: outputs)
        #expect(intValue(moduleCountOutputs.first!) == 4)
    }

    @Test("languageDistribution merges across modules")
    func languageDistributionMerge() async throws {
        var units: [AtomicUnit] = []
        units += makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 3, entityCount: 10,
            languageDistribution: ["swift": 3]
        )
        units += makeModuleUnits(
            startId: 100, moduleName: "Backend",
            modulePath: "/project/Sources/Backend",
            fileCount: 5, entityCount: 15,
            languageDistribution: ["swift": 2, "python": 3]
        )

        let outputs = try await executeHandler(inputSet: units)

        let langOutputs = outputsFor("languageDistribution", domain: "composition", in: outputs)
        #expect(langOutputs.count == 1)
        if case .structured(let langMap) = langOutputs.first!.value {
            if case .integer(let swiftCount) = langMap["swift"] {
                #expect(swiftCount == 5) // 3 + 2
            } else {
                Issue.record("Missing swift in language distribution")
            }
            if case .integer(let pythonCount) = langMap["python"] {
                #expect(pythonCount == 3)
            } else {
                Issue.record("Missing python in language distribution")
            }
        } else {
            Issue.record("languageDistribution is not structured")
        }
    }

    @Test("Missing metadata treated as zero")
    func missingMetadata() async throws {
        // Module with kind but no fileCount or entityCount predicates.
        let units = [makeModuleKindUnit(id: 1, moduleName: "Sparse")]

        let outputs = try await executeHandler(inputSet: units)

        let totalFileOutputs = outputsFor("totalFileCount", domain: "composition", in: outputs)
        #expect(intValue(totalFileOutputs.first!) == 0)

        let totalEntityOutputs = outputsFor("totalEntityCount", domain: "composition", in: outputs)
        #expect(intValue(totalEntityOutputs.first!) == 0)
    }
}

// MARK: - System Naming

@Suite("SystemCompositionPass — System Naming")
struct SCPNamingTests {

    @Test("Common root from sibling directories")
    func siblingDirectories() async throws {
        var units: [AtomicUnit] = []
        units += makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 3, entityCount: 10
        )
        units += makeModuleUnits(
            startId: 100, moduleName: "Domain",
            modulePath: "/project/Sources/Domain",
            fileCount: 5, entityCount: 15
        )

        let outputs = try await executeHandler(inputSet: units)

        let nameOutputs = outputsFor("name", domain: "structure", in: outputs)
        #expect(stringValue(nameOutputs.first!) == "Sources")

        let pathOutputs = outputsFor("path", domain: "structure", in: outputs)
        #expect(stringValue(pathOutputs.first!) == "/project/Sources")
    }

    @Test("Common root from deep heterogeneous paths")
    func heterogeneousPaths() async throws {
        var units: [AtomicUnit] = []
        units += makeModuleUnits(
            startId: 1, moduleName: "Frontend",
            modulePath: "/project/frontend/src",
            fileCount: 3, entityCount: 10
        )
        units += makeModuleUnits(
            startId: 100, moduleName: "Backend",
            modulePath: "/project/backend/app",
            fileCount: 5, entityCount: 15
        )

        let outputs = try await executeHandler(inputSet: units)

        let nameOutputs = outputsFor("name", domain: "structure", in: outputs)
        #expect(stringValue(nameOutputs.first!) == "project")
    }

    @Test("Single module system name is parent directory")
    func singleModuleName() async throws {
        let units = makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 3, entityCount: 10
        )

        let outputs = try await executeHandler(inputSet: units)

        let nameOutputs = outputsFor("name", domain: "structure", in: outputs)
        // Single module: parent of /project/Sources/App is /project/Sources → "Sources"
        #expect(stringValue(nameOutputs.first!) == "Sources")
    }

    @Test("deriveSystemName static function correctness")
    func deriveSystemNameFunction() {
        #expect(SystemCompositionPass.deriveSystemName(from: []) == "system")
        #expect(SystemCompositionPass.deriveSystemName(from: ["/src"]) == "system")
        #expect(SystemCompositionPass.deriveSystemName(
            from: ["/project/App", "/project/Domain"]) == "project")
        #expect(SystemCompositionPass.deriveSystemName(
            from: ["/a/b/c", "/a/b/d"]) == "b")
    }

    @Test("commonRootPath static function correctness")
    func commonRootPathFunction() {
        #expect(SystemCompositionPass.commonRootPath(from: []) == "")
        #expect(SystemCompositionPass.commonRootPath(from: ["/project/App"]) == "/project")
        #expect(SystemCompositionPass.commonRootPath(
            from: ["/project/Sources/App", "/project/Sources/Domain"]) == "/project/Sources")
        #expect(SystemCompositionPass.commonRootPath(
            from: ["/a/b/c", "/a/d/e"]) == "/a")
    }
}

// MARK: - Output Quality

@Suite("SystemCompositionPass — Output Quality")
struct SCPOutputQualityTests {

    @Test("All outputs are T1")
    func allOutputsT1() async throws {
        var units: [AtomicUnit] = []
        units += makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 3, entityCount: 10,
            languageDistribution: ["swift": 3]
        )

        let outputs = try await executeHandler(inputSet: units)
        for output in outputs {
            #expect(output.tier == .t1)
        }
    }

    @Test("All outputs have high confidence")
    func allOutputsHighConfidence() async throws {
        var units: [AtomicUnit] = []
        units += makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 3, entityCount: 10
        )

        let outputs = try await executeHandler(inputSet: units)
        for output in outputs {
            #expect(output.confidence == .high)
        }
    }

    @Test("All outputs have non-empty grounding references")
    func allOutputsGrounded() async throws {
        var units: [AtomicUnit] = []
        units += makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 3, entityCount: 10
        )

        let outputs = try await executeHandler(inputSet: units)
        for output in outputs {
            #expect(!output.groundingRefs.isEmpty)
        }
    }

    @Test("Exactly one kind predicate per system entity")
    func singleKindPredicate() async throws {
        var units: [AtomicUnit] = []
        units += makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 3, entityCount: 10
        )
        units += makeModuleUnits(
            startId: 100, moduleName: "Domain",
            modulePath: "/project/Sources/Domain",
            fileCount: 5, entityCount: 15
        )

        let outputs = try await executeHandler(inputSet: units)
        let kindOutputs = outputsFor("kind", domain: "structure", in: outputs)
        #expect(kindOutputs.count == 1)
    }
}

// MARK: - Idempotency

@Suite("SystemCompositionPass — Idempotency")
struct SCPIdempotencyTests {

    @Test("Same input produces identical output")
    func identicalOutput() async throws {
        var units: [AtomicUnit] = []
        units += makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 3, entityCount: 10
        )
        units += makeModuleUnits(
            startId: 100, moduleName: "Domain",
            modulePath: "/project/Sources/Domain",
            fileCount: 5, entityCount: 15
        )

        let outputs1 = try await executeHandler(inputSet: units)
        let outputs2 = try await executeHandler(inputSet: units)

        #expect(outputs1.count == outputs2.count)

        // Compare each output by predicate and value.
        for (o1, o2) in zip(
            outputs1.sorted { "\($0.predicate)" < "\($1.predicate)" },
            outputs2.sorted { "\($0.predicate)" < "\($1.predicate)" }
        ) {
            #expect(o1.predicate == o2.predicate)
            #expect(o1.tier == o2.tier)
            #expect(o1.confidence == o2.confidence)
        }
    }

    @Test("Reordered input produces same count of outputs")
    func reorderedInput() async throws {
        var units: [AtomicUnit] = []
        units += makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 3, entityCount: 10
        )
        units += makeModuleUnits(
            startId: 100, moduleName: "Domain",
            modulePath: "/project/Sources/Domain",
            fileCount: 5, entityCount: 15
        )

        let outputs1 = try await executeHandler(inputSet: units)
        let outputs2 = try await executeHandler(inputSet: units.reversed())

        #expect(outputs1.count == outputs2.count)

        // Same metadata values regardless of input order.
        let totalFiles1 = outputsFor("totalFileCount", domain: "composition", in: outputs1)
        let totalFiles2 = outputsFor("totalFileCount", domain: "composition", in: outputs2)
        #expect(intValue(totalFiles1.first!) == intValue(totalFiles2.first!))
    }
}

// MARK: - Inactive Unit Handling

@Suite("SystemCompositionPass — Unit Status")
struct SCPUnitStatusTests {

    @Test("Inactive module units are ignored")
    func inactiveUnitsIgnored() async throws {
        let version = VersionStamp(
            singleSource: ContentHash(bytes: Array(repeating: 0, count: 32))
        )
        var inactiveUnit = AtomicUnit(
            id: UnitIdentifier(rawValue: 999),
            subject: .entity(EntityReference(qualifiedName: "module:Ghost")),
            predicate: PredicateIdentifier(name: "kind", domain: "structure"),
            value: .string("module"),
            tier: .t1,
            provenance: ProvenanceRecord(
                producer: "module-boundary-pass",
                method: .derivation,
                timestamp: Date(timeIntervalSince1970: 0)
            ),
            confidence: .high,
            grounding: .derived([]),
            version: version
        )
        inactiveUnit.invalidate(metadata: InvalidationMetadata(
            epoch: Epoch(value: 1),
            reason: .sourceChanged
        ))

        let activeUnits = makeModuleUnits(
            startId: 1, moduleName: "App",
            modulePath: "/project/Sources/App",
            fileCount: 3, entityCount: 10
        )

        let outputs = try await executeHandler(inputSet: activeUnits + [inactiveUnit])

        let moduleCountOutputs = outputsFor("moduleCount", domain: "composition", in: outputs)
        #expect(intValue(moduleCountOutputs.first!) == 1) // Only active module counted
    }
}
