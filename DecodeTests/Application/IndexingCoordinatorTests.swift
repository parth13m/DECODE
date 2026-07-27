import Foundation
import Testing
@testable import Decode

/// Tests for ``IndexingCoordinator`` (W4: Directory Workspace Ingestion).
struct IndexingCoordinatorTests {

    // MARK: - Manifest Scanning

    @Test func scanManifest_discoversSwiftFiles() throws {
        let dir = try Self.makeTempDirectory(files: [
            "main.swift",
            "utils.py",
            "README.md",
            "app.js",
        ])
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let files = IndexingCoordinator.scanManifest(rootURL: URL(fileURLWithPath: dir))

        #expect(files.count == 3)
        #expect(files.contains(where: { $0.hasSuffix("main.swift") }))
        #expect(files.contains(where: { $0.hasSuffix("utils.py") }))
        #expect(files.contains(where: { $0.hasSuffix("app.js") }))
        // README.md should NOT be included
        #expect(!files.contains(where: { $0.hasSuffix("README.md") }))
    }

    @Test func scanManifest_excludesGitDirectory() throws {
        let dir = try Self.makeTempDirectory(files: [
            "src/app.swift",
        ])
        // Create .git/config manually
        let gitDir = "\(dir)/.git"
        try FileManager.default.createDirectory(atPath: gitDir, withIntermediateDirectories: true)
        try "config".write(toFile: "\(gitDir)/config.swift", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let files = IndexingCoordinator.scanManifest(rootURL: URL(fileURLWithPath: dir))

        // .git/config.swift should NOT appear
        #expect(!files.contains(where: { $0.contains(".git") }))
        #expect(files.count == 1)
        #expect(files[0].hasSuffix("app.swift"))
    }

    @Test func scanManifest_excludesNodeModules() throws {
        let dir = try Self.makeTempDirectory(files: [
            "index.js",
        ])
        let nmDir = "\(dir)/node_modules/lodash"
        try FileManager.default.createDirectory(atPath: nmDir, withIntermediateDirectories: true)
        try "module".write(toFile: "\(nmDir)/lodash.js", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let files = IndexingCoordinator.scanManifest(rootURL: URL(fileURLWithPath: dir))

        #expect(files.count == 1)
        #expect(files[0].hasSuffix("index.js"))
    }

    @Test func scanManifest_excludesBuildDirectories() throws {
        let dir = try Self.makeTempDirectory(files: [
            "src/main.swift",
        ])
        for excluded in ["build", "DerivedData", ".build"] {
            let exDir = "\(dir)/\(excluded)"
            try FileManager.default.createDirectory(atPath: exDir, withIntermediateDirectories: true)
            try "x".write(toFile: "\(exDir)/file.swift", atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let files = IndexingCoordinator.scanManifest(rootURL: URL(fileURLWithPath: dir))

        #expect(files.count == 1)
        #expect(files[0].hasSuffix("main.swift"))
    }

    @Test func scanManifest_discoversNestedFiles() throws {
        let dir = try Self.makeTempDirectory(files: [
            "src/main.swift",
            "src/models/User.swift",
            "src/views/ContentView.swift",
            "tests/MainTests.swift",
        ])
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let files = IndexingCoordinator.scanManifest(rootURL: URL(fileURLWithPath: dir))

        #expect(files.count == 4)
    }

    @Test func scanManifest_supportsAllExtensions() throws {
        let dir = try Self.makeTempDirectory(files: [
            "a.swift", "b.py", "c.js", "d.ts", "e.jsx", "f.tsx",
            "g.java", "h.c", "i.cpp", "j.h", "k.hpp", "l.cs",
            "m.html", "n.css",
        ])
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let files = IndexingCoordinator.scanManifest(rootURL: URL(fileURLWithPath: dir))

        #expect(files.count == 14)
    }

    @Test func scanManifest_emptyDirectory() throws {
        let dir = NSTemporaryDirectory() + "decode_test_empty_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let files = IndexingCoordinator.scanManifest(rootURL: URL(fileURLWithPath: dir))

        #expect(files.isEmpty)
    }

    @Test func scanManifest_resultsSorted() throws {
        let dir = try Self.makeTempDirectory(files: [
            "z.swift", "a.swift", "m.swift",
        ])
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let files = IndexingCoordinator.scanManifest(rootURL: URL(fileURLWithPath: dir))

        #expect(files.count == 3)
        #expect(files[0].hasSuffix("a.swift"))
        #expect(files[1].hasSuffix("m.swift"))
        #expect(files[2].hasSuffix("z.swift"))
    }

    // MARK: - Batching

    @Test func makeBatches_exactMultiple() {
        let files = (0..<40).map { "file\($0).swift" }
        let batches = IndexingCoordinator.makeBatches(files: files, batchSize: 20)

        #expect(batches.count == 2)
        #expect(batches[0].count == 20)
        #expect(batches[1].count == 20)
    }

    @Test func makeBatches_withRemainder() {
        let files = (0..<25).map { "file\($0).swift" }
        let batches = IndexingCoordinator.makeBatches(files: files, batchSize: 20)

        #expect(batches.count == 2)
        #expect(batches[0].count == 20)
        #expect(batches[1].count == 5)
    }

    @Test func makeBatches_smallerThanBatch() {
        let files = (0..<5).map { "file\($0).swift" }
        let batches = IndexingCoordinator.makeBatches(files: files, batchSize: 20)

        #expect(batches.count == 1)
        #expect(batches[0].count == 5)
    }

    @Test func makeBatches_empty() {
        let batches = IndexingCoordinator.makeBatches(files: [], batchSize: 20)

        #expect(batches.isEmpty)
    }

    @Test func makeBatches_singleFile() {
        let batches = IndexingCoordinator.makeBatches(files: ["a.swift"], batchSize: 20)

        #expect(batches.count == 1)
        #expect(batches[0] == ["a.swift"])
    }

    // MARK: - IndexingState

    @Test func indexingState_isActive() {
        #expect(!IndexingState.idle.isActive)
        #expect(IndexingState.scanning.isActive)
        #expect(IndexingState.indexing(processed: 5, total: 10).isActive)
        #expect(!IndexingState.complete(fileCount: 10).isActive)
        #expect(!IndexingState.failed("error").isActive)
    }

    @Test func indexingState_progressFraction() {
        #expect(IndexingState.idle.progressFraction == nil)
        #expect(IndexingState.scanning.progressFraction == nil)

        let fraction = IndexingState.indexing(processed: 5, total: 10).progressFraction
        #expect(fraction == 0.5)

        let zeroTotal = IndexingState.indexing(processed: 0, total: 0).progressFraction
        #expect(zeroTotal == nil)

        #expect(IndexingState.complete(fileCount: 10).progressFraction == nil)
    }

    // MARK: - Helpers

    /// Create a temporary directory with the given file structure.
    /// File paths can include subdirectories (e.g., "src/main.swift").
    private static func makeTempDirectory(files: [String]) throws -> String {
        let dir = NSTemporaryDirectory() + "decode_test_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        for filePath in files {
            let fullPath = "\(dir)/\(filePath)"
            let parentDir = (fullPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            try "// test file".write(toFile: fullPath, atomically: true, encoding: .utf8)
        }

        return dir
    }
}
