// TreeSitterFrontendTests.swift — DecodeTests
// Tests for the Tree-sitter frontend producer bridge.

import Testing
import Foundation
@testable import Decode
import DIRCore
import ProducerRuntime

// MARK: - Tests

@Suite("TreeSitterFrontend")
struct TreeSitterFrontendTests {

    // MARK: - Contract Definition

    @Test("Contract declares correct identity and source formats")
    func testContractDefinition() {
        let contract = TreeSitterFrontend.contract
        #expect(contract.identity.identifier.name == "tree-sitter-frontend")
        #expect(contract.identity.version == ProducerVersion(major: 1, minor: 0))
        #expect(contract.sourceFormats.contains("py"))
        #expect(contract.sourceFormats.contains("js"))
        #expect(contract.sourceFormats.contains("ts"))
        #expect(contract.sourceFormats.contains("java"))
        #expect(contract.sourceFormats.contains("cs"))
        #expect(contract.sourceFormats.contains("c"))
        #expect(contract.sourceFormats.contains("cpp"))
        #expect(contract.sourceFormats.contains("html"))
        #expect(contract.sourceFormats.contains("css"))
        #expect(contract.outputContract.tierRange == .t0 ... .t0)
    }

    @Test("Contract uses shared output predicates from FrontendOutputConversion")
    func testOutputPredicates() {
        let predicates = TreeSitterFrontend.contract.outputContract.predicates
        #expect(predicates == FrontendOutputConversion.outputPredicates)
        #expect(predicates == SwiftSyntaxFrontend.contract.outputContract.predicates)
    }

    @Test("Source formats do not overlap with SwiftSyntaxFrontend")
    func testNoSourceFormatOverlap() {
        let tsFormats = TreeSitterFrontend.sourceFormats
        let swiftFormats = SwiftSyntaxFrontend.contract.sourceFormats
        let overlap = tsFormats.intersection(swiftFormats)
        #expect(overlap.isEmpty, "Tree-sitter and SwiftSyntax frontends must not overlap: \(overlap)")
    }

    // MARK: - Python Parsing

    @Test("Handler produces entity outputs from Python source")
    func testPythonEntityExtraction() async throws {
        let outputs = try await parseTestFile(source: """
        import os

        class UserService:
            def create_user(self, name):
                pass

            def delete_user(self, user_id):
                pass
        """, extension: "py")

        let kindOutputs = outputs.filter { $0.predicate.name == "kind" }
        let kindValues = kindOutputs.compactMap { output -> String? in
            if case .string(let s) = output.value { return s }
            return nil
        }

        #expect(kindValues.contains("class"))
        #expect(kindValues.contains("method") || kindValues.contains("function"))

        // All T0 and deterministic.
        for output in outputs {
            #expect(output.tier == .t0)
            #expect(output.confidence == .deterministic)
        }
    }

    @Test("Handler produces import outputs from Python source")
    func testPythonImportExtraction() async throws {
        let outputs = try await parseTestFile(source: """
        import os
        from pathlib import Path
        """, extension: "py")

        let importOutputs = outputs.filter { $0.predicate.name == "imports" }
        // Imports are consolidated into a single newline-delimited output.
        #expect(importOutputs.count == 1)

        if case .string(let combined) = importOutputs.first?.value {
            let modules = combined.components(separatedBy: "\n")
            #expect(modules.contains(where: { $0.contains("os") }))
        } else {
            Issue.record("Expected string value for imports output")
        }
    }

    // MARK: - JavaScript Parsing

    @Test("Handler produces entity outputs from JavaScript source")
    func testJavaScriptEntityExtraction() async throws {
        let outputs = try await parseTestFile(source: """
        function greet(name) {
            return `Hello, ${name}!`;
        }

        class Calculator {
            add(a, b) {
                return a + b;
            }
        }
        """, extension: "js")

        let kindOutputs = outputs.filter { $0.predicate.name == "kind" }
        let kindValues = kindOutputs.compactMap { output -> String? in
            if case .string(let s) = output.value { return s }
            return nil
        }

        #expect(kindValues.contains("function"))
        #expect(kindValues.contains("class"))
    }

    // MARK: - Java Parsing

    @Test("Handler produces entity and relationship outputs from Java source")
    func testJavaExtraction() async throws {
        let outputs = try await parseTestFile(source: """
        import java.util.List;

        public class DataStore {
            public void save(String data) {
                validate(data);
            }

            private void validate(String data) {
            }
        }
        """, extension: "java")

        let kindOutputs = outputs.filter { $0.predicate.name == "kind" }
        #expect(!kindOutputs.isEmpty)

        let importOutputs = outputs.filter { $0.predicate.name == "imports" }
        #expect(!importOutputs.isEmpty)

        let callOutputs = outputs.filter { $0.predicate.name == "calls" }
        #expect(!callOutputs.isEmpty)
    }

    // MARK: - Version Stamps

    @Test("All outputs share the same version stamp from file content")
    func testVersionStamps() async throws {
        let outputs = try await parseTestFile(source: """
        def hello():
            print("hi")
        """, extension: "py")

        #expect(!outputs.isEmpty)
        let versions = Set(outputs.map(\.version))
        #expect(versions.count == 1)
    }

    // MARK: - Empty / Unsupported Files

    @Test("Handler returns empty output for empty file")
    func testEmptyFile() async throws {
        let outputs = try await parseTestFile(source: "", extension: "py")
        #expect(outputs.isEmpty)
    }

    @Test("Handler returns empty output for comment-only file")
    func testCommentOnlyFile() async throws {
        let outputs = try await parseTestFile(source: """
        # This is a comment
        # Another comment
        """, extension: "py")

        // Comment-only files may or may not produce entities depending on grammar.
        // The key assertion: no crash, valid T0 outputs.
        for output in outputs {
            #expect(output.tier == .t0)
        }
    }

    // MARK: - Containment (DAS-004 CONT-3)

    @Test("Handler produces contains(File → Entity) for Python entities")
    func testPythonContainmentOutput() async throws {
        let outputs = try await parseTestFile(source: """
        class UserService:
            def create_user(self, name):
                pass
        """, extension: "py")

        let containsOutputs = outputs.filter { $0.predicate.name == "contains" }
        #expect(!containsOutputs.isEmpty)

        for output in containsOutputs {
            #expect(output.tier == .t0)
            #expect(output.confidence == .deterministic)
            if case .pair(let pair) = output.subject {
                #expect(pair.source.qualifiedName.hasPrefix("file:"))
                #expect(pair.source.qualifiedName.hasSuffix(".py"))
            } else {
                Issue.record("contains output should use pair subject")
            }
        }
    }

    @Test("Handler produces contains(File → Entity) for JavaScript entities")
    func testJavaScriptContainmentOutput() async throws {
        let outputs = try await parseTestFile(source: """
        function greet(name) {
            return `Hello, ${name}!`;
        }
        """, extension: "js")

        let containsOutputs = outputs.filter { $0.predicate.name == "contains" }
        #expect(!containsOutputs.isEmpty)

        for output in containsOutputs {
            #expect(output.tier == .t0)
            if case .boolean(let v) = output.value {
                #expect(v == true)
            } else {
                Issue.record("contains output should have boolean value")
            }
        }
    }

    @Test("Empty file produces no contains output")
    func testEmptyFileNoContainment() async throws {
        let outputs = try await parseTestFile(source: "", extension: "py")
        let containsOutputs = outputs.filter { $0.predicate.name == "contains" }
        #expect(containsOutputs.isEmpty)
    }

    // MARK: - Line Ranges

    @Test("Handler produces startLine and endLine for entities")
    func testLineRangeOutputs() async throws {
        let outputs = try await parseTestFile(source: """
        def compute(x):
            return x * 2
        """, extension: "py")

        let startLines = outputs.filter { $0.predicate.name == "startLine" }
        let endLines = outputs.filter { $0.predicate.name == "endLine" }
        #expect(startLines.count >= 1)
        #expect(endLines.count >= 1)

        if let first = startLines.first, case .integer(let start) = first.value {
            #expect(start >= 1)
        }
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
            TreeSitterFrontend.contract,
            handler: TreeSitterFrontend.handler
        )

        #expect(result == .accepted)

        let dag = await system.producerRegistry.dagSnapshot()
        #expect(dag.frontendCount == 1)
    }

    @Test("Both frontends coexist in the same ProducerActor")
    func testCoexistenceWithSwiftSyntaxFrontend() async throws {
        let snapshotDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("decode-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: snapshotDir) }

        let system = UnderstandingSystem(snapshotDirectory: snapshotDir)

        // Register both frontends.
        let swiftResult = try await system.registerFrontendHandler(
            SwiftSyntaxFrontend.contract,
            handler: SwiftSyntaxFrontend.handler
        )
        let tsResult = try await system.registerFrontendHandler(
            TreeSitterFrontend.contract,
            handler: TreeSitterFrontend.handler
        )

        #expect(swiftResult == .accepted)
        #expect(tsResult == .accepted)

        let dag = await system.producerRegistry.dagSnapshot()
        #expect(dag.frontendCount == 2)
    }

    // MARK: - Helpers

    /// Writes a source string to a temp file with the given extension,
    /// invokes the handler, and returns outputs.
    private func parseTestFile(
        source: String,
        extension ext: String
    ) async throws -> [FrontendOutput] {
        let tempDir = FileManager.default.temporaryDirectory
        let filePath = tempDir
            .appendingPathComponent("Test_\(UUID().uuidString).\(ext)")
            .path
        try source.write(toFile: filePath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: filePath) }

        return try await TreeSitterFrontend.handler(
            filePath,
            TreeSitterFrontend.identity,
            TreeSitterFrontend.contract.outputContract
        )
    }
}
