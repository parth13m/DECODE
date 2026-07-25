// SwiftSyntaxFrontendTests.swift — DecodeTests
// Tests for the SwiftSyntax frontend producer bridge.

import Testing
import Foundation
@testable import Decode
import DIRCore
import ProducerRuntime

// MARK: - Tests

@Suite("SwiftSyntaxFrontend")
struct SwiftSyntaxFrontendTests {

    // MARK: - Contract Definition

    @Test("Contract declares correct identity and source formats")
    func testContractDefinition() {
        let contract = SwiftSyntaxFrontend.contract
        #expect(contract.identity.identifier.name == "swift-syntax-frontend")
        #expect(contract.identity.version == ProducerVersion(major: 1, minor: 0))
        #expect(contract.sourceFormats == ["swift"])
        #expect(contract.outputContract.tierRange == .t0 ... .t0)
    }

    @Test("Output contract declares all expected predicates")
    func testOutputPredicates() {
        let predicates = FrontendOutputConversion.outputPredicates
        let names = Set(predicates.map(\.name))
        #expect(names.contains("kind"))
        #expect(names.contains("signature"))
        #expect(names.contains("startLine"))
        #expect(names.contains("endLine"))
        #expect(names.contains("parentEntity"))
        #expect(names.contains("imports"))
        #expect(names.contains("calls"))
        #expect(names.contains("conformsTo"))
        #expect(names.contains("inherits"))
        #expect(names.contains("owns"))
        #expect(names.contains("contains"))
    }

    // MARK: - Handler Parsing

    @Test("Handler produces entity outputs from Swift source")
    func testEntityExtraction() async throws {
        let outputs = try await parseTestFile(source: """
        import Foundation

        class SessionManager {
            func start() { }
            func stop() { }
        }
        """)

        // Should have entity outputs for SessionManager, start, stop.
        let kindOutputs = outputs.filter { $0.predicate.name == "kind" }
        let kindValues = kindOutputs.compactMap { output -> String? in
            if case .string(let s) = output.value { return s }
            return nil
        }

        #expect(kindValues.contains("class"))
        #expect(kindValues.contains("method"))

        // All outputs must be T0.
        for output in outputs {
            #expect(output.tier == .t0)
            #expect(output.confidence == .deterministic)
        }
    }

    @Test("Handler produces import outputs")
    func testImportExtraction() async throws {
        let outputs = try await parseTestFile(source: """
        import Foundation
        import SwiftUI
        """)

        let importOutputs = outputs.filter { $0.predicate.name == "imports" }
        #expect(importOutputs.count == 2)

        let importValues = importOutputs.compactMap { output -> String? in
            if case .string(let s) = output.value { return s }
            return nil
        }
        #expect(importValues.contains("Foundation"))
        #expect(importValues.contains("SwiftUI"))
    }

    @Test("Handler produces relationship outputs")
    func testRelationshipExtraction() async throws {
        let outputs = try await parseTestFile(source: """
        protocol Configurable { }

        class AppService: Configurable {
            func configure() {
                validate()
            }
            func validate() { }
        }
        """)

        let conformsOutputs = outputs.filter { $0.predicate.name == "conformsTo" }
        #expect(!conformsOutputs.isEmpty)

        // Verify relationship uses EntityPair subject.
        for rel in conformsOutputs {
            if case .pair(let pair) = rel.subject {
                #expect(pair.target.qualifiedName == "Configurable")
            } else {
                Issue.record("Relationship output should use pair subject")
            }
        }

        let callOutputs = outputs.filter { $0.predicate.name == "calls" }
        #expect(!callOutputs.isEmpty)
    }

    @Test("Handler produces version stamps from file content")
    func testVersionStamps() async throws {
        let outputs = try await parseTestFile(source: """
        struct Point { let x: Int; let y: Int }
        """)

        #expect(!outputs.isEmpty)

        // All outputs from the same file should share the same version stamp.
        let versions = Set(outputs.map(\.version))
        #expect(versions.count == 1)
    }

    @Test("Handler produces startLine and endLine for entities")
    func testLineRangeOutputs() async throws {
        let outputs = try await parseTestFile(source: """
        func hello() {
            print("hi")
        }
        """)

        let startLines = outputs.filter { $0.predicate.name == "startLine" }
        let endLines = outputs.filter { $0.predicate.name == "endLine" }
        #expect(startLines.count == 1)
        #expect(endLines.count == 1)

        if case .integer(let start) = startLines[0].value {
            #expect(start >= 1)
        } else {
            Issue.record("startLine should be integer")
        }
    }

    @Test("Handler returns empty output for empty file")
    func testEmptyFile() async throws {
        let outputs = try await parseTestFile(source: "")
        #expect(outputs.isEmpty)
    }

    @Test("Handler produces nested entity parentEntity output")
    func testNestedEntityParent() async throws {
        let outputs = try await parseTestFile(source: """
        class Container {
            struct Inner { }
        }
        """)

        let parentOutputs = outputs.filter { $0.predicate.name == "parentEntity" }
        // Inner should have parentEntity → Container.
        #expect(!parentOutputs.isEmpty)

        if let parent = parentOutputs.first,
           case .reference(let ref) = parent.value {
            #expect(ref.qualifiedName == "Container")
        }
    }

    // MARK: - Containment (DAS-004 CONT-3)

    @Test("Handler produces contains(File → Entity) for each entity")
    func testContainmentOutput() async throws {
        let outputs = try await parseTestFile(source: """
        class SessionManager {
            func start() { }
        }
        """)

        let containsOutputs = outputs.filter { $0.predicate.name == "contains" }
        // SessionManager + SessionManager.start = 2 entities → 2 contains
        #expect(containsOutputs.count == 2)

        for output in containsOutputs {
            #expect(output.tier == .t0)
            #expect(output.confidence == .deterministic)
            if case .pair(let pair) = output.subject {
                #expect(pair.source.qualifiedName.hasPrefix("file:"))
                #expect(pair.source.qualifiedName.hasSuffix(".swift"))
            } else {
                Issue.record("contains output should use pair subject")
            }
            if case .boolean(let v) = output.value {
                #expect(v == true)
            } else {
                Issue.record("contains output should have boolean value")
            }
        }
    }

    @Test("Contains output uses file: prefix and correct entity qualified names")
    func testContainmentPairNames() async throws {
        let outputs = try await parseTestFile(source: """
        struct Point { let x: Int }
        """)

        let containsOutputs = outputs.filter { $0.predicate.name == "contains" }
        let entityNames = containsOutputs.compactMap { output -> String? in
            if case .pair(let pair) = output.subject { return pair.target.qualifiedName }
            return nil
        }
        #expect(entityNames.contains("Point"))
        #expect(entityNames.contains("Point.x"))
    }

    @Test("Empty file produces no contains output")
    func testEmptyFileNoContainment() async throws {
        let outputs = try await parseTestFile(source: "")
        let containsOutputs = outputs.filter { $0.predicate.name == "contains" }
        #expect(containsOutputs.isEmpty)
    }

    // MARK: - ProducerActor Registration

    @Test("Frontend registers with ProducerActor successfully")
    func testProducerActorRegistration() async throws {
        let snapshotDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("decode-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: snapshotDir) }

        let system = UnderstandingSystem(snapshotDirectory: snapshotDir)

        let result = try await system.registerFrontendHandler(
            SwiftSyntaxFrontend.contract,
            handler: SwiftSyntaxFrontend.handler
        )

        #expect(result == .accepted)

        // Verify it appears in the DAG snapshot.
        let dag = await system.producerRegistry.dagSnapshot()
        #expect(dag.frontendCount == 1)
    }

    // MARK: - Helpers

    /// Writes a Swift source string to a temp file, invokes the handler, and returns outputs.
    private func parseTestFile(source: String) async throws -> [FrontendOutput] {
        let tempDir = FileManager.default.temporaryDirectory
        let filePath = tempDir.appendingPathComponent("Test_\(UUID().uuidString).swift").path
        try source.write(toFile: filePath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: filePath) }

        return try await SwiftSyntaxFrontend.handler(
            filePath,
            SwiftSyntaxFrontend.identity,
            SwiftSyntaxFrontend.contract.outputContract
        )
    }
}
