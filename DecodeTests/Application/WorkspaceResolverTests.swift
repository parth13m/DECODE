// WorkspaceResolverTests.swift — DecodeTests
// Unit tests for WorkspaceResolver (W2 dual-stack).
// Mirrors SessionResolverTests for the workspace resolution path.

import Testing
import Foundation
@testable import Decode

// MARK: - Test Helpers

/// Creates a Workspace with sensible defaults for testing.
@MainActor
private func makeWorkspace(
    id: UUID = UUID(),
    kind: WorkspaceKind = .file,
    rootPath: String = "/tmp/test.swift",
    rootFileName: String = "test.swift",
    updatedAt: Date = Date()
) -> Workspace {
    Workspace(
        id: id,
        kind: kind,
        createdAt: Date(),
        updatedAt: updatedAt,
        bookmarkData: Data(),
        rootPath: rootPath,
        rootFileName: rootFileName,
        summaryText: "",
        isCorrupted: false
    )
}

/// Creates a ParsedEntity with the given source text.
@MainActor
private func makeEntity(
    name: String = "testFunc",
    sourceText: String,
    startLine: Int = 1,
    endLine: Int = 10,
    parentStableId: String? = nil
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
        startLine: startLine,
        endLine: endLine,
        sourceText: sourceText,
        fileName: "test.swift",
        parentStableId: parentStableId
    )
}

/// Creates a ManagedWorkspace with the given entities.
@MainActor
private func makeManaged(
    workspace: Workspace,
    entities: [ParsedEntity] = [],
    isFileAccessible: Bool = true
) -> ManagedWorkspace {
    let managed = ManagedWorkspace(
        workspace: workspace,
        parsedEntities: entities
    )
    managed.isFileAccessible = isFileAccessible
    return managed
}

// MARK: - Tests

@Suite(.serialized)
struct WorkspaceResolverTests {

    let resolver = WorkspaceResolver()

    // MARK: - Pinned Workspace Override

    @Test @MainActor
    func pinnedWorkspaceReturnsUnconditionally() {
        let ws = makeWorkspace()
        let managed = makeManaged(workspace: ws)
        let workspaces: [UUID: ManagedWorkspace] = [ws.id: managed]

        let result = resolver.resolve(
            snippet: "func hello() { print(\"world\") }",
            workspaces: workspaces,
            pinnedWorkspaceId: ws.id,
            activeWorkspaceId: nil
        )

        #expect(result.workspace === managed)
        #expect(result.confidence == 100)
        if case .pinned = result.method {} else {
            Issue.record("Expected .pinned method")
        }
    }

    @Test @MainActor
    func pinnedWorkspaceIgnoresOtherCandidates() {
        let pinnedWS = makeWorkspace(rootFileName: "pinned.swift")
        let otherWS = makeWorkspace(rootFileName: "other.swift")
        let snippet = "func exactMatchInOther() { }"
        let otherEntity = makeEntity(
            name: "exactMatchInOther",
            sourceText: "func exactMatchInOther() { }"
        )
        let pinned = makeManaged(workspace: pinnedWS)
        let other = makeManaged(workspace: otherWS, entities: [otherEntity])
        let workspaces: [UUID: ManagedWorkspace] = [
            pinnedWS.id: pinned,
            otherWS.id: other
        ]

        let result = resolver.resolve(
            snippet: snippet,
            workspaces: workspaces,
            pinnedWorkspaceId: pinnedWS.id,
            activeWorkspaceId: otherWS.id
        )

        #expect(result.workspace === pinned)
        if case .pinned = result.method {} else {
            Issue.record("Expected .pinned method")
        }
    }

    // MARK: - Single Workspace Fast Path

    @Test @MainActor
    func singleWorkspaceReturnsDirectly() {
        let ws = makeWorkspace()
        let managed = makeManaged(workspace: ws)
        let workspaces: [UUID: ManagedWorkspace] = [ws.id: managed]

        let result = resolver.resolve(
            snippet: "some code snippet that is long enough",
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: nil
        )

        #expect(result.workspace === managed)
        #expect(result.confidence == 100)
        if case .singleWorkspace = result.method {} else {
            Issue.record("Expected .singleWorkspace method")
        }
    }

    @Test @MainActor
    func singleAccessibleWorkspaceAmongMultiple() {
        let w1 = makeWorkspace(rootFileName: "accessible.swift")
        let w2 = makeWorkspace(rootFileName: "inaccessible.swift")
        let m1 = makeManaged(workspace: w1, isFileAccessible: true)
        let m2 = makeManaged(workspace: w2, isFileAccessible: false)
        let workspaces: [UUID: ManagedWorkspace] = [w1.id: m1, w2.id: m2]

        let result = resolver.resolve(
            snippet: "some long enough snippet text here",
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: nil
        )

        #expect(result.workspace === m1)
        if case .singleWorkspace = result.method {} else {
            Issue.record("Expected .singleWorkspace method")
        }
    }

    // MARK: - Short Snippet Fallback

    @Test @MainActor
    func shortSnippetFallsBackToActive() {
        let w1 = makeWorkspace(rootFileName: "a.swift")
        let w2 = makeWorkspace(rootFileName: "b.swift")
        let m1 = makeManaged(workspace: w1)
        let m2 = makeManaged(workspace: w2)
        let workspaces: [UUID: ManagedWorkspace] = [w1.id: m1, w2.id: m2]

        // "return" is shorter than 15 chars.
        let result = resolver.resolve(
            snippet: "return",
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: w2.id
        )

        #expect(result.workspace === m2)
        #expect(result.confidence == 0)
        if case .fallbackToActive(let reason) = result.method {
            if case .snippetTooShort = reason {} else {
                Issue.record("Expected snippetTooShort reason")
            }
        } else {
            Issue.record("Expected fallbackToActive method")
        }
    }

    @Test @MainActor
    func snippetExactlyAtMinimumLengthProceeds() {
        let w1 = makeWorkspace(rootFileName: "a.swift")
        let w2 = makeWorkspace(rootFileName: "b.swift")
        let entity = makeEntity(
            name: "test",
            sourceText: "import Foundati" // 15 chars, matches snippet
        )
        let m1 = makeManaged(workspace: w1, entities: [entity])
        let m2 = makeManaged(workspace: w2)
        let workspaces: [UUID: ManagedWorkspace] = [w1.id: m1, w2.id: m2]

        let result = resolver.resolve(
            snippet: "import Foundati", // exactly 15 chars
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: w2.id
        )

        // Should NOT fall back due to snippet too short — 15 chars is at the minimum.
        if case .fallbackToActive(let reason) = result.method {
            if case .snippetTooShort = reason {
                Issue.record("Should not be snippet too short at exactly 15 chars")
            }
        }
    }

    // MARK: - Entity Containment Scoring

    @Test @MainActor
    func entityContainmentScoresHighest() {
        let w1 = makeWorkspace(rootFileName: "matched.swift")
        let w2 = makeWorkspace(rootFileName: "unmatched.swift")
        let snippet = "func processData(_ input: [Int]) -> [Int]"
        let entity = makeEntity(
            name: "processData",
            sourceText: "func processData(_ input: [Int]) -> [Int] { return input.sorted() }"
        )
        let m1 = makeManaged(workspace: w1, entities: [entity])
        let m2 = makeManaged(workspace: w2)
        let workspaces: [UUID: ManagedWorkspace] = [w1.id: m1, w2.id: m2]

        let result = resolver.resolve(
            snippet: snippet,
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: w2.id
        )

        #expect(result.workspace === m1)
        if case .autoResolved = result.method {} else {
            Issue.record("Expected .autoResolved method")
        }
        #expect(result.confidence >= 100)
    }

    // MARK: - Normalized Entity Match

    @Test @MainActor
    func normalizedWhitespaceMatchScores80() {
        let w1 = makeWorkspace(rootFileName: "matched.swift")
        let w2 = makeWorkspace(rootFileName: "other.swift")
        // Entity source has different whitespace than snippet.
        let entity = makeEntity(
            name: "process",
            sourceText: "func  process(_ input: [Int])  ->  [Int] { return input }"
        )
        let m1 = makeManaged(workspace: w1, entities: [entity])
        let m2 = makeManaged(workspace: w2)
        let workspaces: [UUID: ManagedWorkspace] = [w1.id: m1, w2.id: m2]

        let result = resolver.resolve(
            snippet: "func process(_ input: [Int]) -> [Int] { return input }",
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: w2.id
        )

        #expect(result.workspace === m1)
        if case .autoResolved = result.method {} else {
            Issue.record("Expected .autoResolved method")
        }
    }

    // MARK: - Ambiguity Detection

    @Test @MainActor
    func ambiguousMatchFallsBackToActive() {
        let w1 = makeWorkspace(rootFileName: "a.swift")
        let w2 = makeWorkspace(rootFileName: "b.swift")
        let snippet = "let value = compute(input)"
        // Both workspaces have entities containing the snippet.
        let e1 = makeEntity(name: "f1", sourceText: "func f1() { let value = compute(input) }")
        let e2 = makeEntity(name: "f2", sourceText: "func f2() { let value = compute(input) }")
        let m1 = makeManaged(workspace: w1, entities: [e1])
        let m2 = makeManaged(workspace: w2, entities: [e2])
        let workspaces: [UUID: ManagedWorkspace] = [w1.id: m1, w2.id: m2]

        let result = resolver.resolve(
            snippet: snippet,
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: w1.id
        )

        // Both score 100 (entity containment) — gap < 10, both ≥ 60 → ambiguous.
        if case .fallbackToActive(let reason) = result.method {
            if case .ambiguous = reason {} else {
                Issue.record("Expected ambiguous reason, got \(reason)")
            }
        } else {
            Issue.record("Expected fallbackToActive method")
        }
    }

    // MARK: - No Match Fallback

    @Test @MainActor
    func noMatchFallsBackToActive() {
        let w1 = makeWorkspace(rootFileName: "a.swift")
        let w2 = makeWorkspace(rootFileName: "b.swift")
        let m1 = makeManaged(workspace: w1)
        let m2 = makeManaged(workspace: w2)
        let workspaces: [UUID: ManagedWorkspace] = [w1.id: m1, w2.id: m2]

        let result = resolver.resolve(
            snippet: "completely unrelated snippet text that matches nothing",
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: w1.id
        )

        #expect(result.workspace === m1)
        #expect(result.confidence == 0)
    }

    // MARK: - No Workspaces

    @Test @MainActor
    func noWorkspacesReturnsNil() {
        let workspaces: [UUID: ManagedWorkspace] = [:]

        let result = resolver.resolve(
            snippet: "some long enough snippet text",
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: nil
        )

        #expect(result.workspace == nil)
        if case .noMatch = result.method {} else {
            Issue.record("Expected .noMatch method")
        }
    }

    @Test @MainActor
    func noActiveWorkspaceAndNoMatchReturnsNil() {
        let w1 = makeWorkspace(rootFileName: "a.swift")
        let m1 = makeManaged(workspace: w1)
        let w2 = makeWorkspace(rootFileName: "b.swift")
        let m2 = makeManaged(workspace: w2)
        let workspaces: [UUID: ManagedWorkspace] = [w1.id: m1, w2.id: m2]

        let result = resolver.resolve(
            snippet: "completely unrelated snippet text that matches nothing",
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: nil // no active workspace
        )

        #expect(result.workspace == nil)
    }

    // MARK: - Recency Bonus

    @Test @MainActor
    func recencyBonusBreaksTie() {
        let now = Date()
        let w1 = makeWorkspace(rootFileName: "old.swift", updatedAt: now.addingTimeInterval(-3600))
        let w2 = makeWorkspace(rootFileName: "recent.swift", updatedAt: now)
        // Both have no entity match, so base score is 0.
        // w2 gets recency bonus of 10 and w1 gets 5 (ranked second).
        // Neither reaches threshold (60), so falls back.
        let m1 = makeManaged(workspace: w1)
        let m2 = makeManaged(workspace: w2)
        let workspaces: [UUID: ManagedWorkspace] = [w1.id: m1, w2.id: m2]

        let result = resolver.resolve(
            snippet: "unrelated long enough snippet text here",
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: nil
        )

        // Both below threshold → no match (no active workspace set).
        #expect(result.workspace == nil)
        // But candidates should be ordered by score, w2 first.
        if let first = result.candidates.first {
            #expect(first.workspace === m2)
        }
    }

    // MARK: - Candidates in Result

    @Test @MainActor
    func candidatesPopulatedForMultipleWorkspaces() {
        let w1 = makeWorkspace(rootFileName: "a.swift")
        let w2 = makeWorkspace(rootFileName: "b.swift")
        let entity = makeEntity(
            name: "test",
            sourceText: "func testMethod() { return someValue }"
        )
        let m1 = makeManaged(workspace: w1, entities: [entity])
        let m2 = makeManaged(workspace: w2)
        let workspaces: [UUID: ManagedWorkspace] = [w1.id: m1, w2.id: m2]

        let result = resolver.resolve(
            snippet: "func testMethod() { return someValue }",
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: nil
        )

        #expect(result.candidates.count == 2)
    }

    // MARK: - Inaccessible Workspaces Filtered

    @Test @MainActor
    func inaccessibleWorkspacesExcludedFromScoring() {
        let w1 = makeWorkspace(rootFileName: "a.swift")
        let entity = makeEntity(
            name: "test",
            sourceText: "func exactMatchHere() { return 42 }"
        )
        let m1 = makeManaged(workspace: w1, entities: [entity])
        m1.isFileAccessible = false
        let workspaces: [UUID: ManagedWorkspace] = [w1.id: m1]

        let result = resolver.resolve(
            snippet: "func exactMatchHere() { return 42 }",
            workspaces: workspaces,
            pinnedWorkspaceId: nil,
            activeWorkspaceId: nil
        )

        // No accessible workspaces → noMatch.
        #expect(result.workspace == nil)
    }
}

// MARK: - Resolution Types Tests

@Suite
struct WorkspaceResolutionMethodTests {

    @Test func descriptionStrings() {
        #expect(WorkspaceResolutionMethod.pinned.description == "pinned")
        #expect(WorkspaceResolutionMethod.singleWorkspace.description == "single-workspace")
        #expect(WorkspaceResolutionMethod.autoResolved.description == "auto-resolved")
        #expect(WorkspaceResolutionMethod.noMatch.description == "no-match")
        #expect(WorkspaceResolutionMethod.fallbackToActive(.snippetTooShort).description == "fallback-to-active(snippet-too-short)")
        #expect(WorkspaceResolutionMethod.fallbackToActive(.lowConfidence).description == "fallback-to-active(low-confidence)")
        #expect(WorkspaceResolutionMethod.fallbackToActive(.ambiguous).description == "fallback-to-active(ambiguous)")
        #expect(WorkspaceResolutionMethod.fallbackToActive(.noWorkspaces).description == "fallback-to-active(no-workspaces)")
    }
}

@Suite
struct WorkspaceMatchTypeTests {

    @Test func descriptionStrings() {
        #expect(WorkspaceMatchType.entityContainment.description == "entity-containment")
        #expect(WorkspaceMatchType.normalizedEntityContainment.description == "normalized-entity")
        #expect(WorkspaceMatchType.fileContent.description == "file-content")
        #expect(WorkspaceMatchType.singleWorkspace.description == "single-workspace")
        #expect(WorkspaceMatchType.noMatch.description == "no-match")
    }
}
