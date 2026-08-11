// GroundingInvariantTests.swift — DecodeTests
// Platform grounding invariant: every source-extracted AtomicUnit
// must carry a valid SourcePosition with non-empty filePath,
// correct startLine/endLine, and the canonical content hash.

import Testing
import Foundation
@testable import Decode
import DIRCore
import ProducerRuntime
import RetrievalRuntime
import UpdateEngine

// MARK: - Tree-sitter Grounding Tests

@Suite("Grounding Invariant — TreeSitter")
struct TreeSitterGroundingTests {

    @Test("Entity outputs carry valid source position")
    func entityOutputsHaveValidSourcePosition() async throws {
        let outputs = try await parseTreeSitterFile(source: """
        class Patient:
            def __init__(self):
                self.name = "test"

        def insert_patient_data():
            pass
        """, extension: "py")

        let entityOutputs = outputs.filter {
            if case .entity = $0.subject { return true }
            return false
        }
        #expect(!entityOutputs.isEmpty)

        for output in entityOutputs {
            #expect(output.sourceFilePath != nil, "Entity output must have sourceFilePath")
            #expect(output.sourceFilePath != "", "Entity output sourceFilePath must not be empty")
            #expect(output.sourceStartLine != nil, "Entity output must have sourceStartLine")
            #expect(output.sourceStartLine! > 0, "Entity output sourceStartLine must be > 0")
            #expect(output.sourceEndLine != nil, "Entity output must have sourceEndLine")
            #expect(output.sourceEndLine! >= output.sourceStartLine!, "sourceEndLine must be >= sourceStartLine")
        }
    }

    @Test("Two entities in the same file produce different source ranges")
    func twoEntitiesHaveDifferentRanges() async throws {
        let outputs = try await parseTreeSitterFile(source: """
        class Alpha:
            pass

        class Beta:
            pass
        """, extension: "py")

        // Get kind outputs (one per entity) which carry source position
        let kindOutputs = outputs.filter { $0.predicate.name == "kind" }
        #expect(kindOutputs.count >= 2)

        let ranges = kindOutputs.map { ($0.sourceStartLine!, $0.sourceEndLine!) }
        let uniqueRanges = Set(ranges.map { "\($0.0)-\($0.1)" })
        #expect(uniqueRanges.count >= 2, "Different entities must have different source ranges")
    }

    @Test("Entity sourceFilePath matches the actual parsed file path")
    func sourceFilePathMatchesParsedPath() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let filePath = tempDir.appendingPathComponent("Test_\(UUID().uuidString).py").path
        try "def hello(): pass".write(toFile: filePath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: filePath) }

        let outputs = try await TreeSitterFrontend.handler(
            filePath,
            TreeSitterFrontend.identity,
            TreeSitterFrontend.contract.outputContract
        )

        let entityOutputs = outputs.filter {
            if case .entity = $0.subject { return true }
            return false
        }
        for output in entityOutputs {
            #expect(output.sourceFilePath == filePath,
                    "sourceFilePath must match the parsed file path exactly")
        }
    }

    @Test("File-level outputs carry sourceFilePath but no line range")
    func fileLevelOutputsHaveFilePathOnly() async throws {
        let outputs = try await parseTreeSitterFile(source: """
        import os
        import sys
        """, extension: "py")

        let importOutputs = outputs.filter { $0.predicate.name == "imports" }
        #expect(!importOutputs.isEmpty)

        for output in importOutputs {
            #expect(output.sourceFilePath != nil, "Import output must have sourceFilePath")
            #expect(output.sourceFilePath != "", "Import output sourceFilePath must not be empty")
            // File-level outputs have no specific line range
            #expect(output.sourceStartLine == nil)
            #expect(output.sourceEndLine == nil)
        }
    }

    // MARK: - Helpers

    private func parseTreeSitterFile(source: String, extension ext: String) async throws -> [FrontendOutput] {
        let tempDir = FileManager.default.temporaryDirectory
        let filePath = tempDir.appendingPathComponent("Test_\(UUID().uuidString).\(ext)").path
        try source.write(toFile: filePath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: filePath) }
        return try await TreeSitterFrontend.handler(
            filePath, TreeSitterFrontend.identity, TreeSitterFrontend.contract.outputContract
        )
    }
}

// MARK: - Swift Producer Grounding Tests

@Suite("Grounding Invariant — SwiftSyntax")
struct SwiftSyntaxGroundingTests {

    @Test("Entity outputs carry valid source position")
    func entityOutputsHaveValidSourcePosition() async throws {
        let outputs = try await parseSwiftFile(source: """
        class Manager {
            func start() { }
            func stop() { }
        }
        """)

        let entityOutputs = outputs.filter {
            if case .entity = $0.subject { return true }
            return false
        }
        #expect(!entityOutputs.isEmpty)

        for output in entityOutputs {
            #expect(output.sourceFilePath != nil)
            #expect(output.sourceFilePath != "")
            #expect(output.sourceStartLine != nil)
            #expect(output.sourceStartLine! > 0)
            #expect(output.sourceEndLine != nil)
            #expect(output.sourceEndLine! >= output.sourceStartLine!)
        }
    }

    @Test("Two entities produce different source ranges")
    func twoEntitiesHaveDifferentRanges() async throws {
        let outputs = try await parseSwiftFile(source: """
        struct Alpha { }
        struct Beta { }
        """)

        let kindOutputs = outputs.filter { $0.predicate.name == "kind" }
        #expect(kindOutputs.count >= 2)

        let ranges = kindOutputs.map { ($0.sourceStartLine!, $0.sourceEndLine!) }
        let uniqueRanges = Set(ranges.map { "\($0.0)-\($0.1)" })
        #expect(uniqueRanges.count >= 2)
    }

    // MARK: - Helpers

    private func parseSwiftFile(source: String) async throws -> [FrontendOutput] {
        let tempDir = FileManager.default.temporaryDirectory
        let filePath = tempDir.appendingPathComponent("Test_\(UUID().uuidString).swift").path
        try source.write(toFile: filePath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: filePath) }
        return try await SwiftSyntaxFrontend.handler(
            filePath, SwiftSyntaxFrontend.identity, SwiftSyntaxFrontend.contract.outputContract
        )
    }
}

// MARK: - Snippet Resolution After Grounding Tests

@Suite("Grounding Invariant — Snippet Resolution")
struct GroundingSnippetResolutionTests {

    @Test("SnippetReference resolves entity after grounding is populated")
    func snippetResolvesEntityWithGrounding() async throws {
        let snapshotDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("decode-grounding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: snapshotDir) }

        // Create a Python file with two entities
        let fileDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("decode-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fileDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fileDir) }

        let filePath = fileDir.appendingPathComponent("model.py").path
        try """
        class Patient:
            def __init__(self):
                self.name = "test"

        def insert_data():
            pass
        """.write(toFile: filePath, atomically: true, encoding: .utf8)

        let system = UnderstandingSystem(snapshotDirectory: snapshotDir)
        _ = try await system.registerFrontendHandler(
            TreeSitterFrontend.contract, handler: TreeSitterFrontend.handler
        )
        await system.start()

        // Process the file through the pipeline
        let event = UpdateEngine.FileChangeEvent(filePath: filePath, changeType: .modified)
        _ = await system.processChanges([event])

        // Now resolve a snippet that overlaps the Patient class
        let snippet = SnippetReference(filePath: filePath, startLine: 1, endLine: 3)
        let anchors = await system.evidenceRetrieval.resolveAnchors(for: .snippet(snippet))

        #expect(!anchors.isEmpty, "Snippet overlapping an entity must resolve to at least one anchor")
    }

    @Test("Selection spanning multiple entities produces multiple anchors")
    func multiEntitySnippetProducesMultipleAnchors() async throws {
        let snapshotDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("decode-grounding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: snapshotDir) }

        let fileDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("decode-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fileDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fileDir) }

        let filePath = fileDir.appendingPathComponent("multi.py").path
        try """
        class Alpha:
            pass

        class Beta:
            pass
        """.write(toFile: filePath, atomically: true, encoding: .utf8)

        let system = UnderstandingSystem(snapshotDirectory: snapshotDir)
        _ = try await system.registerFrontendHandler(
            TreeSitterFrontend.contract, handler: TreeSitterFrontend.handler
        )
        await system.start()

        let event = UpdateEngine.FileChangeEvent(filePath: filePath, changeType: .modified)
        _ = await system.processChanges([event])

        // Snippet spanning both classes
        let snippet = SnippetReference(filePath: filePath, startLine: 1, endLine: 5)
        let anchors = await system.evidenceRetrieval.resolveAnchors(for: .snippet(snippet))

        #expect(anchors.count >= 2, "Snippet spanning two entities should resolve to at least 2 anchors")
    }

    @Test("File-scope fallback resolves canonical file entity")
    func fileScopeFallbackResolvesCanonicalEntity() async throws {
        let snapshotDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("decode-grounding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: snapshotDir) }

        let fileDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("decode-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fileDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fileDir) }

        let filePath = fileDir.appendingPathComponent("simple.py").path
        try """
        class OnlyEntity:
            pass
        """.write(toFile: filePath, atomically: true, encoding: .utf8)

        let system = UnderstandingSystem(snapshotDirectory: snapshotDir)
        _ = try await system.registerFrontendHandler(
            TreeSitterFrontend.contract, handler: TreeSitterFrontend.handler
        )
        await system.start()

        let event = UpdateEngine.FileChangeEvent(filePath: filePath, changeType: .modified)
        _ = await system.processChanges([event])

        // Snippet at lines 100-110 — outside entity range, should fall back to file entity
        let snippet = SnippetReference(filePath: filePath, startLine: 100, endLine: 110)
        let anchors = await system.evidenceRetrieval.resolveAnchors(for: .snippet(snippet))

        #expect(!anchors.isEmpty, "File-scope fallback should resolve to the canonical file entity")
        if let first = anchors.first {
            #expect(first.qualifiedName.hasPrefix("file:"),
                    "File-scope entity should use canonical 'file:' prefix")
        }
    }
}
