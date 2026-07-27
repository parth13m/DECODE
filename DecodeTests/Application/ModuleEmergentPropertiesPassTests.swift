// ModuleEmergentPropertiesPassTests.swift — DecodeTests
// M4: Tests for module emergent properties composition pass.

import Testing
import Foundation
@testable import Decode
import ProducerRuntime
import DIRCore

// MARK: - Test Helpers

private let testVersion = VersionStamp(
    singleSource: ContentHash(bytes: Array(repeating: 0, count: 32))
)

private let testProvenance = ProvenanceRecord(
    producer: "test-frontend",
    method: .extraction,
    timestamp: Date(timeIntervalSince1970: 0),
    inputUnitIds: []
)

/// Creates a T0 kind:structure unit for an entity.
private func makeEntityKindUnit(
    id: UInt64,
    qualifiedName: String,
    filePath: String,
    kind: String = "class"
) -> AtomicUnit {
    AtomicUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .entity(EntityReference(qualifiedName: qualifiedName)),
        predicate: PredicateIdentifier(name: "kind", domain: "structure"),
        value: .string(kind),
        tier: .t0,
        provenance: testProvenance,
        confidence: .deterministic,
        grounding: .direct(SourcePosition(
            filePath: filePath, startLine: 1, endLine: 10,
            fileVersion: ContentHash(bytes: Array(repeating: 0, count: 32))
        )),
        version: testVersion
    )
}

/// Creates a T1 kind:structure unit for a module entity (from ModuleBoundaryPass).
private func makeModuleKindUnit(
    id: UInt64,
    moduleName: String
) -> AtomicUnit {
    AtomicUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .entity(EntityReference(qualifiedName: "module:\(moduleName)")),
        predicate: PredicateIdentifier(name: "kind", domain: "structure"),
        value: .string("module"),
        tier: .t1,
        provenance: ProvenanceRecord(
            producer: "module-boundary-pass",
            method: .derivation,
            timestamp: Date(timeIntervalSince1970: 0),
            inputUnitIds: []
        ),
        confidence: .high,
        grounding: .derived([]),
        version: testVersion
    )
}

/// Creates a T0 relationship unit (intra-file, symbolic target).
private func makeT0RelationshipUnit(
    id: UInt64,
    sourceName: String,
    targetName: String,
    filePath: String,
    relationship: String = "calls"
) -> AtomicUnit {
    AtomicUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .pair(EntityPair(
            source: EntityReference(qualifiedName: sourceName),
            target: EntityReference(qualifiedName: targetName)
        )),
        predicate: PredicateIdentifier(name: relationship, domain: "relationship"),
        value: .boolean(true),
        tier: .t0,
        provenance: testProvenance,
        confidence: .deterministic,
        grounding: .direct(SourcePosition(
            filePath: filePath, startLine: 5, endLine: 5,
            fileVersion: ContentHash(bytes: Array(repeating: 0, count: 32))
        )),
        version: testVersion
    )
}

/// Creates a T1 resolved relationship unit (cross-file, from CrossFileResolutionPass).
private func makeT1RelationshipUnit(
    id: UInt64,
    sourceName: String,
    targetName: String,
    relationship: String = "calls"
) -> AtomicUnit {
    AtomicUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .pair(EntityPair(
            source: EntityReference(qualifiedName: sourceName),
            target: EntityReference(qualifiedName: targetName)
        )),
        predicate: PredicateIdentifier(name: relationship, domain: "relationship"),
        value: .boolean(true),
        tier: .t1,
        provenance: ProvenanceRecord(
            producer: "cross-file-resolution-pass",
            method: .derivation,
            timestamp: Date(timeIntervalSince1970: 0),
            inputUnitIds: []
        ),
        confidence: .high,
        grounding: .derived([]),
        version: testVersion
    )
}

/// Invokes the handler.
private func executeHandler(inputSet: [AtomicUnit]) async throws -> [PassOutput] {
    let scopeWindow = ScopeWindow(
        entities: Set(inputSet.compactMap { unit -> EntityReference? in
            if case .entity(let ref) = unit.subject { return ref }
            return nil
        }),
        identifier: ScopeWindowIdentifier("system")
    )
    return try await ModuleEmergentPropertiesPass.handler(
        inputSet, scopeWindow,
        ModuleEmergentPropertiesPass.identity,
        OutputContract(
            predicates: ModuleEmergentPropertiesPass.outputPredicates,
            tierRange: .t1 ... .t1
        ),
        nil
    )
}

/// Filters outputs by predicate name.
private func outputsFor(_ name: String, in outputs: [PassOutput]) -> [PassOutput] {
    outputs.filter { $0.predicate == PredicateIdentifier(name: name, domain: "emergence") }
}

/// Extracts structured value as dictionary.
private func structuredValue(_ output: PassOutput) -> [String: TypedValue]? {
    if case .structured(let map) = output.value { return map }
    return nil
}

/// Extracts integer from a TypedValue.
private func intVal(_ tv: TypedValue?) -> Int64? {
    if case .integer(let v) = tv { return v }
    return nil
}

/// Extracts float from a TypedValue.
private func floatVal(_ tv: TypedValue?) -> Double? {
    if case .float(let v) = tv { return v }
    return nil
}

/// Extracts string from a TypedValue.
private func stringVal(_ tv: TypedValue?) -> String? {
    if case .string(let v) = tv { return v }
    return nil
}

/// Extracts the module name from an output's subject.
private func moduleName(_ output: PassOutput) -> String? {
    if case .entity(let ref) = output.subject {
        let qn = ref.qualifiedName
        if qn.hasPrefix("module:") {
            return String(qn.dropFirst("module:".count))
        }
    }
    return nil
}

// MARK: - Contract Tests

@Suite("ModuleEmergentPropertiesPass Contract")
struct MEPContractTests {

    @Test("Identity has correct identifier and version")
    func identity() {
        let id = ModuleEmergentPropertiesPass.identity
        #expect(id.identifier.name == "module-emergent-properties-pass")
        #expect(id.version.major == 1)
        #expect(id.version.minor == 0)
    }

    @Test("Contract declares perSystem scope")
    func scopeIsPerSystem() {
        #expect(ModuleEmergentPropertiesPass.contract.scope == .perSystem)
    }

    @Test("Contract is not a composition pass")
    func isNotComposition() {
        #expect(ModuleEmergentPropertiesPass.contract.isComposition == false)
    }

    @Test("Contract is idempotent")
    func isIdempotent() {
        #expect(ModuleEmergentPropertiesPass.contract.isIdempotent == true)
    }

    @Test("Contract depends on module-boundary-pass and cross-file-resolution-pass")
    func dependencies() {
        let deps = ModuleEmergentPropertiesPass.contract.dependencies
        #expect(deps.contains(ProducerIdentifier(name: "module-boundary-pass")))
        #expect(deps.contains(ProducerIdentifier(name: "cross-file-resolution-pass")))
    }

    @Test("Contract reads T0 and T1 input")
    func inputTiers() {
        #expect(ModuleEmergentPropertiesPass.contract.inputContract.tiers == [.t0, .t1])
    }

    @Test("Contract outputs T1 only")
    func outputTiers() {
        #expect(ModuleEmergentPropertiesPass.contract.outputContract.tierRange == .t1 ... .t1)
    }

    @Test("Output predicates are in emergence domain")
    func outputPredicates() {
        let preds = ModuleEmergentPropertiesPass.outputPredicates
        #expect(preds.count == 5)
        for pred in preds {
            #expect(pred.domain == "emergence")
        }
    }

    @Test("Execution strategy is deterministic")
    func executionStrategy() {
        #expect(ModuleEmergentPropertiesPass.contract.executionStrategy == .deterministic)
    }
}

// MARK: - Cohesion Tests

@Suite("ModuleEmergentPropertiesPass Cohesion")
struct CohesionTests {

    @Test("Highly cohesive module: all relationships internal")
    func highlyCohesive() async throws {
        // ModuleA: two entities that call each other, no external relationships.
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "ClassA", filePath: "/src/ModA/A.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "ClassB", filePath: "/src/ModA/B.swift"),
            makeModuleKindUnit(id: 100, moduleName: "ModA"),
            // T0 intra-file call
            makeT0RelationshipUnit(id: 10, sourceName: "ClassA", targetName: "helper", filePath: "/src/ModA/A.swift"),
            // T1 intra-module cross-file call
            makeT1RelationshipUnit(id: 11, sourceName: "ClassA", targetName: "ClassB"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let cohesionOutputs = outputsFor("cohesion", in: outputs)
        #expect(cohesionOutputs.count == 1)

        let map = structuredValue(cohesionOutputs[0])!
        #expect(intVal(map["internal"]) == 2) // 1 T0 + 1 T1 intra-module
        #expect(intVal(map["external"]) == 0)
        #expect(floatVal(map["ratio"]) == 1.0)
    }

    @Test("Low cohesion: mostly external relationships")
    func lowCohesion() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "ClassA", filePath: "/src/ModA/A.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "ClassX", filePath: "/src/ModB/X.swift"),
            makeEntityKindUnit(id: 3, qualifiedName: "ClassY", filePath: "/src/ModB/Y.swift"),
            makeModuleKindUnit(id: 100, moduleName: "ModA"),
            makeModuleKindUnit(id: 101, moduleName: "ModB"),
            // ClassA calls both ClassX and ClassY (cross-module).
            makeT1RelationshipUnit(id: 10, sourceName: "ClassA", targetName: "ClassX"),
            makeT1RelationshipUnit(id: 11, sourceName: "ClassA", targetName: "ClassY"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let modAOutputs = outputsFor("cohesion", in: outputs).filter { moduleName($0) == "ModA" }
        #expect(modAOutputs.count == 1)

        let map = structuredValue(modAOutputs[0])!
        #expect(intVal(map["internal"]) == 0)
        #expect(intVal(map["external"]) == 2)
        #expect(floatVal(map["ratio"]) == 0.0)
    }

    @Test("Empty module: default cohesion ratio is 1.0")
    func emptyModuleCohesion() async throws {
        let units: [AtomicUnit] = [
            makeModuleKindUnit(id: 100, moduleName: "Empty"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let cohesionOutputs = outputsFor("cohesion", in: outputs)
        #expect(cohesionOutputs.count == 1)

        let map = structuredValue(cohesionOutputs[0])!
        #expect(intVal(map["internal"]) == 0)
        #expect(intVal(map["external"]) == 0)
        #expect(floatVal(map["ratio"]) == 1.0)
    }

    @Test("Mixed cohesion: some internal, some external")
    func mixedCohesion() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "A", filePath: "/src/Mod/A.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "B", filePath: "/src/Mod/B.swift"),
            makeEntityKindUnit(id: 3, qualifiedName: "Ext", filePath: "/src/Other/Ext.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Mod"),
            makeModuleKindUnit(id: 101, moduleName: "Other"),
            // 2 internal: T0 + T1 intra-module
            makeT0RelationshipUnit(id: 10, sourceName: "A", targetName: "helper", filePath: "/src/Mod/A.swift"),
            makeT1RelationshipUnit(id: 11, sourceName: "A", targetName: "B"),
            // 1 external: outbound to Other
            makeT1RelationshipUnit(id: 12, sourceName: "A", targetName: "Ext"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let modOutputs = outputsFor("cohesion", in: outputs).filter { moduleName($0) == "Mod" }
        let map = structuredValue(modOutputs[0])!

        #expect(intVal(map["internal"]) == 2)
        #expect(intVal(map["external"]) == 1)
        // ratio = 2/3 ≈ 0.667
        let ratio = floatVal(map["ratio"])!
        #expect(ratio > 0.66 && ratio < 0.67)
    }
}

// MARK: - Public Interface Tests

@Suite("ModuleEmergentPropertiesPass Public Interface")
struct PublicInterfaceTests {

    @Test("Entities referenced from outside module appear in public interface")
    func externallyReferencedEntities() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "Service", filePath: "/src/Infra/Service.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "Controller", filePath: "/src/App/Controller.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Infra"),
            makeModuleKindUnit(id: 101, moduleName: "App"),
            // Controller (App) calls Service (Infra) — Service is part of Infra's public interface.
            makeT1RelationshipUnit(id: 10, sourceName: "Controller", targetName: "Service"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let infraPI = outputsFor("publicInterface", in: outputs).filter { moduleName($0) == "Infra" }
        #expect(infraPI.count == 1)

        let map = structuredValue(infraPI[0])!
        #expect(intVal(map["count"]) == 1)
        #expect(stringVal(map["entities"]) == "Service")
    }

    @Test("Module with no external references has empty public interface")
    func noExternalReferences() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "Internal", filePath: "/src/Mod/Internal.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Mod"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let pi = outputsFor("publicInterface", in: outputs)
        #expect(pi.count == 1)

        let map = structuredValue(pi[0])!
        #expect(intVal(map["count"]) == 0)
        #expect(stringVal(map["entities"]) == "")
    }

    @Test("Multiple externally referenced entities are sorted")
    func multipleEntitiesSorted() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "Zebra", filePath: "/src/Lib/Z.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "Alpha", filePath: "/src/Lib/A.swift"),
            makeEntityKindUnit(id: 3, qualifiedName: "Caller", filePath: "/src/App/C.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Lib"),
            makeModuleKindUnit(id: 101, moduleName: "App"),
            makeT1RelationshipUnit(id: 10, sourceName: "Caller", targetName: "Zebra"),
            makeT1RelationshipUnit(id: 11, sourceName: "Caller", targetName: "Alpha"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let pi = outputsFor("publicInterface", in: outputs).filter { moduleName($0) == "Lib" }
        let map = structuredValue(pi[0])!

        #expect(intVal(map["count"]) == 2)
        #expect(stringVal(map["entities"]) == "Alpha, Zebra")
    }

    @Test("Intra-module references do not appear in public interface")
    func intraModuleNotPublic() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "A", filePath: "/src/Mod/A.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "B", filePath: "/src/Mod/B.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Mod"),
            makeT1RelationshipUnit(id: 10, sourceName: "A", targetName: "B"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let pi = outputsFor("publicInterface", in: outputs)
        let map = structuredValue(pi[0])!
        #expect(intVal(map["count"]) == 0)
    }
}

// MARK: - Interaction Profile Tests

@Suite("ModuleEmergentPropertiesPass Interaction Profile")
struct InteractionProfileTests {

    @Test("Delegation-heavy module: mostly calls")
    func delegationHeavy() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "A", filePath: "/src/Mod/A.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "B", filePath: "/src/Mod/B.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Mod"),
            makeT0RelationshipUnit(id: 10, sourceName: "A", targetName: "helper", filePath: "/src/Mod/A.swift"),
            makeT1RelationshipUnit(id: 11, sourceName: "A", targetName: "B"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let ip = outputsFor("interactionProfile", in: outputs)
        let map = structuredValue(ip[0])!

        #expect(intVal(map["calls"]) == 2)
        #expect(intVal(map["conformsTo"]) == 0)
        #expect(intVal(map["inherits"]) == 0)
    }

    @Test("Protocol-heavy module: mostly conformsTo")
    func protocolHeavy() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "Impl", filePath: "/src/Mod/Impl.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "Proto", filePath: "/src/Mod/Proto.swift", kind: "protocol"),
            makeModuleKindUnit(id: 100, moduleName: "Mod"),
            makeT0RelationshipUnit(id: 10, sourceName: "Impl", targetName: "Proto", filePath: "/src/Mod/Impl.swift", relationship: "conformsTo"),
            makeT1RelationshipUnit(id: 11, sourceName: "Impl", targetName: "Proto", relationship: "conformsTo"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let ip = outputsFor("interactionProfile", in: outputs)
        let map = structuredValue(ip[0])!

        #expect(intVal(map["calls"]) == 0)
        #expect(intVal(map["conformsTo"]) == 2)
        #expect(intVal(map["inherits"]) == 0)
    }

    @Test("Mixed interaction profile")
    func mixedProfile() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "A", filePath: "/src/M/A.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "B", filePath: "/src/M/B.swift"),
            makeModuleKindUnit(id: 100, moduleName: "M"),
            makeT0RelationshipUnit(id: 10, sourceName: "A", targetName: "x", filePath: "/src/M/A.swift"),
            makeT0RelationshipUnit(id: 11, sourceName: "A", targetName: "Proto", filePath: "/src/M/A.swift", relationship: "conformsTo"),
            makeT0RelationshipUnit(id: 12, sourceName: "B", targetName: "Base", filePath: "/src/M/B.swift", relationship: "inherits"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let ip = outputsFor("interactionProfile", in: outputs)
        let map = structuredValue(ip[0])!

        #expect(intVal(map["calls"]) == 1)
        #expect(intVal(map["conformsTo"]) == 1)
        #expect(intVal(map["inherits"]) == 1)
    }
}

// MARK: - Boundary Profile Tests

@Suite("ModuleEmergentPropertiesPass Boundary Profile")
struct BoundaryProfileTests {

    @Test("Module with inbound and outbound calls")
    func inboundAndOutbound() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "Svc", filePath: "/src/Infra/Svc.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "Ctrl", filePath: "/src/App/Ctrl.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Infra"),
            makeModuleKindUnit(id: 101, moduleName: "App"),
            // App → Infra (inbound for Infra, outbound for App)
            makeT1RelationshipUnit(id: 10, sourceName: "Ctrl", targetName: "Svc"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        // Infra: 1 inbound call
        let infraBP = outputsFor("boundaryProfile", in: outputs).filter { moduleName($0) == "Infra" }
        let infraMap = structuredValue(infraBP[0])!
        #expect(intVal(infraMap["inboundCalls"]) == 1)
        #expect(intVal(infraMap["outboundCalls"]) == 0)

        // App: 1 outbound call
        let appBP = outputsFor("boundaryProfile", in: outputs).filter { moduleName($0) == "App" }
        let appMap = structuredValue(appBP[0])!
        #expect(intVal(appMap["inboundCalls"]) == 0)
        #expect(intVal(appMap["outboundCalls"]) == 1)
    }

    @Test("Boundary with multiple relationship types")
    func multipleTypes() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "Impl", filePath: "/src/A/Impl.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "Proto", filePath: "/src/B/Proto.swift", kind: "protocol"),
            makeEntityKindUnit(id: 3, qualifiedName: "Base", filePath: "/src/B/Base.swift"),
            makeModuleKindUnit(id: 100, moduleName: "A"),
            makeModuleKindUnit(id: 101, moduleName: "B"),
            makeT1RelationshipUnit(id: 10, sourceName: "Impl", targetName: "Proto", relationship: "conformsTo"),
            makeT1RelationshipUnit(id: 11, sourceName: "Impl", targetName: "Base", relationship: "inherits"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let aBP = outputsFor("boundaryProfile", in: outputs).filter { moduleName($0) == "A" }
        let aMap = structuredValue(aBP[0])!

        #expect(intVal(aMap["outboundConformsTo"]) == 1)
        #expect(intVal(aMap["outboundInherits"]) == 1)
        #expect(intVal(aMap["outboundCalls"]) == 0)
    }

    @Test("Isolated module has all-zero boundary")
    func isolatedBoundary() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "Solo", filePath: "/src/Alone/Solo.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Alone"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let bp = outputsFor("boundaryProfile", in: outputs)
        let map = structuredValue(bp[0])!

        for key in ["inboundCalls", "outboundCalls", "inboundConformsTo", "outboundConformsTo", "inboundInherits", "outboundInherits"] {
            #expect(intVal(map[key]) == 0)
        }
    }
}

// MARK: - Module Role Tests

@Suite("ModuleEmergentPropertiesPass Module Role")
struct ModuleRoleTests {

    @Test("Provider: only inbound relationships")
    func providerRole() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "Svc", filePath: "/src/Infra/Svc.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "Ctrl", filePath: "/src/App/Ctrl.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Infra"),
            makeModuleKindUnit(id: 101, moduleName: "App"),
            makeT1RelationshipUnit(id: 10, sourceName: "Ctrl", targetName: "Svc"),
            makeT1RelationshipUnit(id: 11, sourceName: "Ctrl", targetName: "Svc"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let role = outputsFor("moduleRole", in: outputs).filter { moduleName($0) == "Infra" }
        if case .string(let v) = role[0].value {
            #expect(v == "provider")
        } else {
            Issue.record("Expected string value")
        }
    }

    @Test("Consumer: only outbound relationships")
    func consumerRole() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "Svc", filePath: "/src/Infra/Svc.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "Ctrl", filePath: "/src/App/Ctrl.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Infra"),
            makeModuleKindUnit(id: 101, moduleName: "App"),
            makeT1RelationshipUnit(id: 10, sourceName: "Ctrl", targetName: "Svc"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let role = outputsFor("moduleRole", in: outputs).filter { moduleName($0) == "App" }
        if case .string(let v) = role[0].value {
            #expect(v == "consumer")
        } else {
            Issue.record("Expected string value")
        }
    }

    @Test("Isolated: no cross-module relationships")
    func isolatedRole() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "Solo", filePath: "/src/Alone/Solo.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Alone"),
            // Only T0 intra-file relationships
            makeT0RelationshipUnit(id: 10, sourceName: "Solo", targetName: "helper", filePath: "/src/Alone/Solo.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let role = outputsFor("moduleRole", in: outputs)
        if case .string(let v) = role[0].value {
            #expect(v == "isolated")
        } else {
            Issue.record("Expected string value")
        }
        // Isolated role gets .high confidence
        #expect(role[0].confidence == .high)
    }

    @Test("Mixed: balanced inbound and outbound")
    func mixedRole() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "A", filePath: "/src/Mid/A.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "B", filePath: "/src/Up/B.swift"),
            makeEntityKindUnit(id: 3, qualifiedName: "C", filePath: "/src/Down/C.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Mid"),
            makeModuleKindUnit(id: 101, moduleName: "Up"),
            makeModuleKindUnit(id: 102, moduleName: "Down"),
            // Mid calls Down (outbound)
            makeT1RelationshipUnit(id: 10, sourceName: "A", targetName: "C"),
            // Up calls Mid (inbound for Mid)
            makeT1RelationshipUnit(id: 11, sourceName: "B", targetName: "A"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let role = outputsFor("moduleRole", in: outputs).filter { moduleName($0) == "Mid" }
        if case .string(let v) = role[0].value {
            #expect(v == "mixed")
        } else {
            Issue.record("Expected string value")
        }
        // Non-isolated roles get .moderate confidence
        #expect(role[0].confidence == .moderate)
    }

    @Test("Provider threshold: inbound >= 2 * outbound")
    func providerThreshold() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "Svc", filePath: "/src/S/Svc.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "C1", filePath: "/src/C/C1.swift"),
            makeEntityKindUnit(id: 3, qualifiedName: "C2", filePath: "/src/C/C2.swift"),
            makeEntityKindUnit(id: 4, qualifiedName: "Dep", filePath: "/src/D/Dep.swift"),
            makeModuleKindUnit(id: 100, moduleName: "S"),
            makeModuleKindUnit(id: 101, moduleName: "C"),
            makeModuleKindUnit(id: 102, moduleName: "D"),
            // 2 inbound calls to S
            makeT1RelationshipUnit(id: 10, sourceName: "C1", targetName: "Svc"),
            makeT1RelationshipUnit(id: 11, sourceName: "C2", targetName: "Svc"),
            // 1 outbound call from S
            makeT1RelationshipUnit(id: 12, sourceName: "Svc", targetName: "Dep"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let role = outputsFor("moduleRole", in: outputs).filter { moduleName($0) == "S" }
        if case .string(let v) = role[0].value {
            #expect(v == "provider")
        } else {
            Issue.record("Expected string value")
        }
    }
}

// MARK: - Module Role Classifier Tests

@Suite("ModuleEmergentPropertiesPass Role Classifier")
struct RoleClassifierTests {

    @Test("Zero/zero → isolated")
    func zeroZero() {
        #expect(ModuleEmergentPropertiesPass.classifyModuleRole(inbound: 0, outbound: 0) == "isolated")
    }

    @Test("Inbound only → provider")
    func inboundOnly() {
        #expect(ModuleEmergentPropertiesPass.classifyModuleRole(inbound: 5, outbound: 0) == "provider")
    }

    @Test("Outbound only → consumer")
    func outboundOnly() {
        #expect(ModuleEmergentPropertiesPass.classifyModuleRole(inbound: 0, outbound: 3) == "consumer")
    }

    @Test("2:1 ratio → provider")
    func twoToOneProvider() {
        #expect(ModuleEmergentPropertiesPass.classifyModuleRole(inbound: 4, outbound: 2) == "provider")
    }

    @Test("1:2 ratio → consumer")
    func oneToTwoConsumer() {
        #expect(ModuleEmergentPropertiesPass.classifyModuleRole(inbound: 2, outbound: 4) == "consumer")
    }

    @Test("Balanced → mixed")
    func balanced() {
        #expect(ModuleEmergentPropertiesPass.classifyModuleRole(inbound: 3, outbound: 3) == "mixed")
    }

    @Test("Slightly unbalanced → mixed")
    func slightlyUnbalanced() {
        #expect(ModuleEmergentPropertiesPass.classifyModuleRole(inbound: 3, outbound: 2) == "mixed")
    }
}

// MARK: - Edge Case Tests

@Suite("ModuleEmergentPropertiesPass Edge Cases")
struct MEPEdgeCaseTests {

    @Test("Empty input produces no output")
    func emptyInput() async throws {
        let outputs = try await executeHandler(inputSet: [])
        #expect(outputs.isEmpty)
    }

    @Test("No module entities produces no output")
    func noModules() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "A", filePath: "/src/A.swift"),
        ]
        let outputs = try await executeHandler(inputSet: units)
        #expect(outputs.isEmpty)
    }

    @Test("Single-file module produces all five properties")
    func singleFileModule() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "Solo", filePath: "/src/Mod/Solo.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Mod"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        // 5 properties for 1 module
        #expect(outputs.count == 5)
        #expect(outputsFor("cohesion", in: outputs).count == 1)
        #expect(outputsFor("publicInterface", in: outputs).count == 1)
        #expect(outputsFor("interactionProfile", in: outputs).count == 1)
        #expect(outputsFor("boundaryProfile", in: outputs).count == 1)
        #expect(outputsFor("moduleRole", in: outputs).count == 1)
    }

    @Test("Multiple modules each get five properties")
    func multipleModules() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "A", filePath: "/src/ModA/A.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "B", filePath: "/src/ModB/B.swift"),
            makeModuleKindUnit(id: 100, moduleName: "ModA"),
            makeModuleKindUnit(id: 101, moduleName: "ModB"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        #expect(outputs.count == 10) // 5 per module
    }

    @Test("Relationship with unknown entity module is ignored")
    func unknownEntityModule() async throws {
        let units: [AtomicUnit] = [
            makeModuleKindUnit(id: 100, moduleName: "Mod"),
            // Relationship between entities not in any entity kind unit
            makeT1RelationshipUnit(id: 10, sourceName: "Unknown", targetName: "AlsoUnknown"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let cohesion = outputsFor("cohesion", in: outputs)
        let map = structuredValue(cohesion[0])!
        #expect(intVal(map["internal"]) == 0)
        #expect(intVal(map["external"]) == 0)
    }
}

// MARK: - Tier and Confidence Tests

@Suite("ModuleEmergentPropertiesPass Tier and Confidence")
struct TierConfidenceTests {

    @Test("All outputs are T1")
    func allOutputsAreT1() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "A", filePath: "/src/Mod/A.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Mod"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        for output in outputs {
            #expect(output.tier == .t1)
        }
    }

    @Test("Metric properties have high confidence")
    func metricConfidence() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "A", filePath: "/src/Mod/A.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Mod"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        for output in outputs {
            if output.predicate.name != "moduleRole" {
                #expect(output.confidence == .high)
            }
        }
    }

    @Test("Non-isolated moduleRole has moderate confidence")
    func roleConfidence() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "A", filePath: "/src/Mod/A.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "B", filePath: "/src/Other/B.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Mod"),
            makeModuleKindUnit(id: 101, moduleName: "Other"),
            makeT1RelationshipUnit(id: 10, sourceName: "A", targetName: "B"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let role = outputsFor("moduleRole", in: outputs).filter { moduleName($0) == "Mod" }
        #expect(role[0].confidence == .moderate)
    }
}

// MARK: - Grounding Tests

@Suite("ModuleEmergentPropertiesPass Grounding")
struct MEPGroundingTests {

    @Test("Grounding includes module kind unit ID")
    func groundingIncludesModuleKind() async throws {
        let moduleKindId: UInt64 = 100
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "A", filePath: "/src/Mod/A.swift"),
            makeModuleKindUnit(id: moduleKindId, moduleName: "Mod"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        for output in outputs {
            #expect(output.groundingRefs.contains(UnitIdentifier(rawValue: moduleKindId)))
        }
    }

    @Test("Grounding includes relationship unit IDs")
    func groundingIncludesRelationships() async throws {
        let relId: UInt64 = 10
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "A", filePath: "/src/Mod/A.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Mod"),
            makeT0RelationshipUnit(id: relId, sourceName: "A", targetName: "x", filePath: "/src/Mod/A.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)
        let cohesion = outputsFor("cohesion", in: outputs)
        #expect(cohesion[0].groundingRefs.contains(UnitIdentifier(rawValue: relId)))
    }
}

// MARK: - Idempotency Tests

@Suite("ModuleEmergentPropertiesPass Idempotency")
struct MEPIdempotencyTests {

    @Test("Running the handler twice produces identical output")
    func idempotent() async throws {
        let units: [AtomicUnit] = [
            makeEntityKindUnit(id: 1, qualifiedName: "A", filePath: "/src/Mod/A.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "B", filePath: "/src/Mod/B.swift"),
            makeEntityKindUnit(id: 3, qualifiedName: "C", filePath: "/src/Other/C.swift"),
            makeModuleKindUnit(id: 100, moduleName: "Mod"),
            makeModuleKindUnit(id: 101, moduleName: "Other"),
            makeT0RelationshipUnit(id: 10, sourceName: "A", targetName: "x", filePath: "/src/Mod/A.swift"),
            makeT1RelationshipUnit(id: 11, sourceName: "A", targetName: "B"),
            makeT1RelationshipUnit(id: 12, sourceName: "A", targetName: "C"),
        ]

        let outputs1 = try await executeHandler(inputSet: units)
        let outputs2 = try await executeHandler(inputSet: units)

        #expect(outputs1.count == outputs2.count)
        // Sort both by subject+predicate for deterministic comparison.
        let sorted1 = outputs1.sorted { "\($0.subject)\($0.predicate)" < "\($1.subject)\($1.predicate)" }
        let sorted2 = outputs2.sorted { "\($0.subject)\($0.predicate)" < "\($1.subject)\($1.predicate)" }

        for (o1, o2) in zip(sorted1, sorted2) {
            #expect(o1.subject == o2.subject)
            #expect(o1.predicate == o2.predicate)
            #expect(o1.value == o2.value)
            #expect(o1.tier == o2.tier)
            #expect(o1.confidence == o2.confidence)
        }
    }
}

// MARK: - Complex Scenario Tests

@Suite("ModuleEmergentPropertiesPass Complex Scenarios")
struct ComplexScenarioTests {

    @Test("Three-module system with layered dependencies")
    func threeModuleLayered() async throws {
        // Presentation → Application → Infrastructure
        let units: [AtomicUnit] = [
            // Entities
            makeEntityKindUnit(id: 1, qualifiedName: "HUD", filePath: "/src/Presentation/HUD.swift"),
            makeEntityKindUnit(id: 2, qualifiedName: "Coordinator", filePath: "/src/Application/Coord.swift"),
            makeEntityKindUnit(id: 3, qualifiedName: "Service", filePath: "/src/Infrastructure/Svc.swift"),
            makeEntityKindUnit(id: 4, qualifiedName: "Protocol", filePath: "/src/Application/Proto.swift", kind: "protocol"),
            // Modules
            makeModuleKindUnit(id: 100, moduleName: "Presentation"),
            makeModuleKindUnit(id: 101, moduleName: "Application"),
            makeModuleKindUnit(id: 102, moduleName: "Infrastructure"),
            // HUD → Coordinator (Presentation calls Application)
            makeT1RelationshipUnit(id: 10, sourceName: "HUD", targetName: "Coordinator"),
            // Coordinator → Service (Application calls Infrastructure)
            makeT1RelationshipUnit(id: 11, sourceName: "Coordinator", targetName: "Service"),
            // Service conforms to Protocol (Infrastructure conformsTo Application)
            makeT1RelationshipUnit(id: 12, sourceName: "Service", targetName: "Protocol", relationship: "conformsTo"),
            // Intra-Application call
            makeT0RelationshipUnit(id: 13, sourceName: "Coordinator", targetName: "validate", filePath: "/src/Application/Coord.swift"),
        ]

        let outputs = try await executeHandler(inputSet: units)

        // Application: 1 inbound (HUD→Coordinator), 1 outbound (Coordinator→Service),
        // 1 inbound conformsTo (Service→Protocol), 1 internal call
        let appRole = outputsFor("moduleRole", in: outputs).filter { moduleName($0) == "Application" }
        // inbound = 1 call + 1 conformsTo = 2, outbound = 1 call
        // 2 >= 2*1 → provider
        if case .string(let v) = appRole[0].value {
            #expect(v == "provider")
        }

        let appCohesion = outputsFor("cohesion", in: outputs).filter { moduleName($0) == "Application" }
        let cohMap = structuredValue(appCohesion[0])!
        #expect(intVal(cohMap["internal"]) == 1) // 1 T0 intra-file call
        #expect(intVal(cohMap["external"]) == 1) // 1 outbound call

        // Application's public interface: Coordinator (called by HUD) and Protocol (conformed by Service)
        let appPI = outputsFor("publicInterface", in: outputs).filter { moduleName($0) == "Application" }
        let piMap = structuredValue(appPI[0])!
        #expect(intVal(piMap["count"]) == 2)

        // Infrastructure: 1 inbound call (HUD→Coordinator→Service) + 1 outbound conformsTo → mixed
        let infraRole = outputsFor("moduleRole", in: outputs).filter { moduleName($0) == "Infrastructure" }
        if case .string(let v) = infraRole[0].value {
            #expect(v == "mixed") // 1 inbound call + 1 outbound conformsTo
        }

        // Presentation: only outbound (consumer)
        let presRole = outputsFor("moduleRole", in: outputs).filter { moduleName($0) == "Presentation" }
        if case .string(let v) = presRole[0].value {
            #expect(v == "consumer")
        }
    }
}
