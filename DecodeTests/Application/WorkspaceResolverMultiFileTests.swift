import Foundation
import Testing
@testable import Decode

/// Tests for multi-file resolution within `.directory` workspaces (W7).
@Suite(.serialized)
struct WorkspaceResolverMultiFileTests {

    let resolver = WorkspaceResolver()

    // MARK: - Helpers

    @MainActor
    private func makeDirectoryWorkspace(
        id: UUID = UUID(),
        rootPath: String = "/tmp/project",
        rootFileName: String = "project",
        entitiesByFile: [String: [ParsedEntity]] = [:],
        updatedAt: Date = Date()
    ) -> ManagedWorkspace {
        let workspace = Workspace(
            id: id,
            kind: .directory,
            createdAt: Date(),
            updatedAt: updatedAt,
            bookmarkData: Data(),
            rootPath: rootPath,
            rootFileName: rootFileName,
            summaryText: "",
            isCorrupted: false
        )
        let allEntities = entitiesByFile.values.flatMap { $0 }
        let managed = ManagedWorkspace(
            workspace: workspace,
            parsedEntities: allEntities
        )
        managed.parsedEntitiesByFile = entitiesByFile
        return managed
    }

    @MainActor
    private func makeFileWorkspace(
        id: UUID = UUID(),
        rootPath: String = "/tmp/test.swift",
        rootFileName: String = "test.swift",
        entities: [ParsedEntity] = [],
        updatedAt: Date = Date()
    ) -> ManagedWorkspace {
        let workspace = Workspace(
            id: id,
            kind: .file,
            createdAt: Date(),
            updatedAt: updatedAt,
            bookmarkData: Data(),
            rootPath: rootPath,
            rootFileName: rootFileName,
            summaryText: "",
            isCorrupted: false
        )
        return ManagedWorkspace(
            workspace: workspace,
            parsedEntities: entities
        )
    }

    private func makeEntity(
        name: String,
        sourceText: String
    ) -> ParsedEntity {
        let entity = CodeEntity(
            id: UUID(),
            sessionId: UUID(),
            stableId: "\(name)_stable",
            entityType: .function,
            name: name,
            summaryText: "",
            hash: "hash_\(name)",
            lastUpdated: Date()
        )
        return ParsedEntity(
            entity: entity,
            signature: "func \(name)()",
            startLine: 1,
            endLine: 10,
            sourceText: sourceText,
            fileName: "test.swift",
            parentStableId: nil
        )
    }

    // MARK: - Entity Containment Across Files

    @Test @MainActor
    func snippetMatchesEntityInDirectoryFile() {
        let snippet = "func processData(_ input: [Int]) -> [Int]"
        let entity = makeEntity(
            name: "processData",
            sourceText: "func processData(_ input: [Int]) -> [Int] { return input.sorted() }"
        )
        let dirWorkspace = makeDirectoryWorkspace(
            entitiesByFile: [
                "/tmp/project/Sources/main.swift": [],
                "/tmp/project/Sources/utils.swift": [entity],
            ]
        )
        // Add a second workspace so the resolver goes through scoring
        // (single-workspace short-circuits without file matching).
        let otherWorkspace = makeFileWorkspace(
            rootPath: "/tmp/other.swift",
            rootFileName: "other.swift"
        )
        let workspaces: [UUID: ManagedWorkspace] = [
            dirWorkspace.id: dirWorkspace,
            otherWorkspace.id: otherWorkspace,
        ]

        let result = resolver.resolve(
            snippet: snippet,
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: nil
        )

        #expect(result.workspace === dirWorkspace)
        #expect(result.resolvedFilePath == "/tmp/project/Sources/utils.swift")
        if case .autoResolved = result.method {} else {
            Issue.record("Expected .autoResolved, got \(result.method)")
        }
    }

    @Test @MainActor
    func snippetNotMatchingAnyFileReturnsNil() {
        let entity = makeEntity(
            name: "unrelated",
            sourceText: "func unrelated() { print(\"hello\") }"
        )
        let dirWorkspace = makeDirectoryWorkspace(
            entitiesByFile: ["/tmp/project/main.swift": [entity]]
        )
        let otherWorkspace = makeFileWorkspace(
            rootPath: "/tmp/other.swift",
            rootFileName: "other.swift"
        )
        let workspaces: [UUID: ManagedWorkspace] = [
            dirWorkspace.id: dirWorkspace,
            otherWorkspace.id: otherWorkspace,
        ]

        let result = resolver.resolve(
            snippet: "completely different code that matches nothing at all",
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: nil
        )

        // No match → noMatch (no active workspace set).
        #expect(result.workspace == nil)
        #expect(result.resolvedFilePath == nil)
    }

    @Test @MainActor
    func pinnedDirectoryWorkspaceOverrides() {
        let dirWorkspace = makeDirectoryWorkspace(
            entitiesByFile: ["/tmp/project/main.swift": []]
        )
        let workspaces: [UUID: ManagedWorkspace] = [dirWorkspace.id: dirWorkspace]

        let result = resolver.resolve(
            snippet: "func someFunction() { return 42 }",
            workspaces: workspaces,
            pinnedWorkspaceId: dirWorkspace.id,
            activeWorkspaceId: nil
        )

        #expect(result.workspace === dirWorkspace)
        if case .pinned = result.method {} else {
            Issue.record("Expected .pinned method")
        }
    }

    @Test @MainActor
    func directoryWorkspaceBeatsFileWorkspaceByEntityMatch() {
        let snippet = "func calculateTotal(_ items: [Double]) -> Double"
        let entity = makeEntity(
            name: "calculateTotal",
            sourceText: "func calculateTotal(_ items: [Double]) -> Double { items.reduce(0, +) }"
        )
        let dirWorkspace = makeDirectoryWorkspace(
            rootPath: "/tmp/project",
            entitiesByFile: ["/tmp/project/Sources/calc.swift": [entity]]
        )
        let fileWorkspace = makeFileWorkspace(
            rootPath: "/tmp/other.swift",
            rootFileName: "other.swift"
        )
        let workspaces: [UUID: ManagedWorkspace] = [
            dirWorkspace.id: dirWorkspace,
            fileWorkspace.id: fileWorkspace,
        ]

        let result = resolver.resolve(
            snippet: snippet,
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: fileWorkspace.id
        )

        #expect(result.workspace === dirWorkspace)
        #expect(result.resolvedFilePath == "/tmp/project/Sources/calc.swift")
    }

    @Test @MainActor
    func normalizedMatchWorksAcrossDirectoryFiles() {
        let entity = makeEntity(
            name: "process",
            sourceText: "func  process(_ input:  [Int])  ->  [Int] { return input }"
        )
        let dirWorkspace = makeDirectoryWorkspace(
            entitiesByFile: ["/tmp/project/src/handler.swift": [entity]]
        )
        let otherWorkspace = makeFileWorkspace(
            rootPath: "/tmp/other.swift",
            rootFileName: "other.swift"
        )
        let workspaces: [UUID: ManagedWorkspace] = [
            dirWorkspace.id: dirWorkspace,
            otherWorkspace.id: otherWorkspace,
        ]

        let result = resolver.resolve(
            snippet: "func process(_ input: [Int]) -> [Int] { return input }",
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: nil
        )

        #expect(result.workspace === dirWorkspace)
        #expect(result.resolvedFilePath == "/tmp/project/src/handler.swift")
    }

    @Test @MainActor
    func emptyParsedEntitiesByFileDoesNotCrash() {
        let dirWorkspace = makeDirectoryWorkspace(
            entitiesByFile: [:]
        )
        let otherWorkspace = makeFileWorkspace(
            rootPath: "/tmp/other.swift",
            rootFileName: "other.swift"
        )
        let workspaces: [UUID: ManagedWorkspace] = [
            dirWorkspace.id: dirWorkspace,
            otherWorkspace.id: otherWorkspace,
        ]

        let result = resolver.resolve(
            snippet: "some long enough snippet text here that is unique",
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: nil
        )

        // No entity match in either workspace, no active → noMatch.
        #expect(result.workspace == nil)
    }

    @Test @MainActor
    func resolvedFilePathNilForFileWorkspace() {
        let entity = makeEntity(
            name: "hello",
            sourceText: "func hello() { print(\"world\") }"
        )
        let fileWorkspace = makeFileWorkspace(
            entities: [entity]
        )
        let dirWorkspace = makeDirectoryWorkspace(
            entitiesByFile: ["/tmp/project/main.swift": []]
        )
        let workspaces: [UUID: ManagedWorkspace] = [
            fileWorkspace.id: fileWorkspace,
            dirWorkspace.id: dirWorkspace,
        ]

        let result = resolver.resolve(
            snippet: "func hello() { print(\"world\") }",
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: nil
        )

        // .file workspace match → resolvedFilePath should be nil (single file, not directory).
        #expect(result.workspace === fileWorkspace)
        #expect(result.resolvedFilePath == nil)
    }

    @Test @MainActor
    func candidatesIncludeMatchedFilePath() {
        let entity = makeEntity(
            name: "doWork",
            sourceText: "func doWork() { let x = 42; return x }"
        )
        let dirWorkspace = makeDirectoryWorkspace(
            entitiesByFile: ["/tmp/project/worker.swift": [entity]]
        )
        let fileWorkspace = makeFileWorkspace()
        let workspaces: [UUID: ManagedWorkspace] = [
            dirWorkspace.id: dirWorkspace,
            fileWorkspace.id: fileWorkspace,
        ]

        let result = resolver.resolve(
            snippet: "func doWork() { let x = 42; return x }",
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: nil
        )

        let dirCandidate = result.candidates.first { $0.workspace === dirWorkspace }
        #expect(dirCandidate?.matchedFilePath == "/tmp/project/worker.swift")

        let fileCandidate = result.candidates.first { $0.workspace === fileWorkspace }
        #expect(fileCandidate?.matchedFilePath == nil)
    }
}
