// SessionResolverTests.swift — DecodeTests
// Comprehensive unit tests for SessionResolver.

import Testing
import Foundation
@testable import Decode

// MARK: - Test Helpers

/// Creates a Session with sensible defaults for testing.
@MainActor
private func makeSession(
    id: UUID = UUID(),
    filePath: String = "/tmp/test.swift",
    fileName: String = "test.swift",
    updatedAt: Date = Date()
) -> Session {
    Session(
        id: id,
        createdAt: Date(),
        updatedAt: updatedAt,
        bookmarkData: Data(),
        filePath: filePath,
        fileName: fileName,
        fileSize: 1000,
        fileModifiedAt: Date(),
        fileHash: "abc123",
        summaryText: "",
        isCorrupted: false
    )
}

/// Creates a ParsedEntity with the given source text.
@MainActor
private func makeEntity(
    sessionId: UUID = UUID(),
    name: String = "testFunc",
    sourceText: String,
    startLine: Int = 1,
    endLine: Int = 10,
    parentStableId: String? = nil
) -> ParsedEntity {
    let entity = CodeEntity(
        id: UUID(),
        sessionId: sessionId,
        stableId: "\(name)_stable",
        entityType: .function,
        name: name,
        summaryText: "",
        bodyHash: "hash_\(name)"
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

/// Creates a ManagedSession with the given entities.
@MainActor
private func makeManaged(
    session: Session,
    entities: [ParsedEntity] = [],
    isFileAccessible: Bool = true
) -> ManagedSession {
    let managed = ManagedSession(
        session: session,
        parsedEntities: entities
    )
    managed.isFileAccessible = isFileAccessible
    return managed
}

// MARK: - Tests

@Suite(.serialized)
struct SessionResolverTests {

    let resolver = SessionResolver()

    // MARK: - Pinned Session Override

    @Test @MainActor
    func pinnedSessionReturnsUnconditionally() {
        let session = makeSession()
        let managed = makeManaged(session: session)
        let sessions: [UUID: ManagedSession] = [session.id: managed]

        let result = resolver.resolve(
            snippet: "func hello() { print(\"world\") }",
            sessions: sessions,
            pinnedSessionId: session.id,
            activeSessionId: nil
        )

        #expect(result.session === managed)
        #expect(result.confidence == 100)
        if case .pinned = result.method {} else {
            Issue.record("Expected .pinned method")
        }
    }

    @Test @MainActor
    func pinnedSessionIgnoresOtherCandidates() {
        let pinnedSession = makeSession(fileName: "pinned.swift")
        let otherSession = makeSession(fileName: "other.swift")
        let snippet = "func exactMatchInOther() { }"
        let otherEntity = makeEntity(
            name: "exactMatchInOther",
            sourceText: "func exactMatchInOther() { }"
        )
        let pinned = makeManaged(session: pinnedSession)
        let other = makeManaged(session: otherSession, entities: [otherEntity])
        let sessions: [UUID: ManagedSession] = [
            pinnedSession.id: pinned,
            otherSession.id: other
        ]

        let result = resolver.resolve(
            snippet: snippet,
            sessions: sessions,
            pinnedSessionId: pinnedSession.id,
            activeSessionId: otherSession.id
        )

        #expect(result.session === pinned)
        if case .pinned = result.method {} else {
            Issue.record("Expected .pinned method")
        }
    }

    // MARK: - Single Session Fast Path

    @Test @MainActor
    func singleSessionReturnsDirectly() {
        let session = makeSession()
        let managed = makeManaged(session: session)
        let sessions: [UUID: ManagedSession] = [session.id: managed]

        let result = resolver.resolve(
            snippet: "some code snippet that is long enough",
            sessions: sessions,
            pinnedSessionId: nil,
            activeSessionId: nil
        )

        #expect(result.session === managed)
        #expect(result.confidence == 100)
        if case .singleSession = result.method {} else {
            Issue.record("Expected .singleSession method")
        }
    }

    @Test @MainActor
    func singleAccessibleSessionAmongMultiple() {
        let s1 = makeSession(fileName: "accessible.swift")
        let s2 = makeSession(fileName: "inaccessible.swift")
        let m1 = makeManaged(session: s1, isFileAccessible: true)
        let m2 = makeManaged(session: s2, isFileAccessible: false)
        let sessions: [UUID: ManagedSession] = [s1.id: m1, s2.id: m2]

        let result = resolver.resolve(
            snippet: "some long enough snippet text here",
            sessions: sessions,
            pinnedSessionId: nil,
            activeSessionId: nil
        )

        #expect(result.session === m1)
        if case .singleSession = result.method {} else {
            Issue.record("Expected .singleSession method")
        }
    }

    // MARK: - Short Snippet Fallback

    @Test @MainActor
    func shortSnippetFallsBackToActive() {
        let s1 = makeSession(fileName: "a.swift")
        let s2 = makeSession(fileName: "b.swift")
        let m1 = makeManaged(session: s1)
        let m2 = makeManaged(session: s2)
        let sessions: [UUID: ManagedSession] = [s1.id: m1, s2.id: m2]

        // "return" is shorter than 15 chars.
        let result = resolver.resolve(
            snippet: "return",
            sessions: sessions,
            pinnedSessionId: nil,
            activeSessionId: s2.id
        )

        #expect(result.session === m2)
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
        let s1 = makeSession(fileName: "a.swift")
        let s2 = makeSession(fileName: "b.swift")
        let entity = makeEntity(
            name: "test",
            sourceText: "import Foundati" // 15 chars, matches snippet
        )
        let m1 = makeManaged(session: s1, entities: [entity])
        let m2 = makeManaged(session: s2)
        let sessions: [UUID: ManagedSession] = [s1.id: m1, s2.id: m2]

        let result = resolver.resolve(
            snippet: "import Foundati", // exactly 15 chars
            sessions: sessions,
            pinnedSessionId: nil,
            activeSessionId: s2.id
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
        let s1 = makeSession(fileName: "matched.swift")
        let s2 = makeSession(fileName: "unmatched.swift")
        let snippet = "func processData(_ input: [Int]) -> [Int]"
        let entity = makeEntity(
            name: "processData",
            sourceText: "func processData(_ input: [Int]) -> [Int] { return input.sorted() }"
        )
        let m1 = makeManaged(session: s1, entities: [entity])
        let m2 = makeManaged(session: s2)
        let sessions: [UUID: ManagedSession] = [s1.id: m1, s2.id: m2]

        let result = resolver.resolve(
            snippet: snippet,
            sessions: sessions,
            pinnedSessionId: nil,
            activeSessionId: s2.id
        )

        #expect(result.session === m1)
        if case .autoResolved = result.method {} else {
            Issue.record("Expected .autoResolved method")
        }
        #expect(result.confidence >= 100)
    }

    // MARK: - Normalized Entity Match

    @Test @MainActor
    func normalizedWhitespaceMatchScores80() {
        let s1 = makeSession(fileName: "matched.swift")
        let s2 = makeSession(fileName: "other.swift")
        // Entity source has different whitespace than snippet.
        let entity = makeEntity(
            name: "process",
            sourceText: "func  process(_ input: [Int])  ->  [Int] { return input }"
        )
        let m1 = makeManaged(session: s1, entities: [entity])
        let m2 = makeManaged(session: s2)
        let sessions: [UUID: ManagedSession] = [s1.id: m1, s2.id: m2]

        let result = resolver.resolve(
            snippet: "func process(_ input: [Int]) -> [Int] { return input }",
            sessions: sessions,
            pinnedSessionId: nil,
            activeSessionId: s2.id
        )

        #expect(result.session === m1)
        if case .autoResolved = result.method {} else {
            Issue.record("Expected .autoResolved method")
        }
    }

    // MARK: - Ambiguity Detection

    @Test @MainActor
    func ambiguousMatchFallsBackToActive() {
        let s1 = makeSession(fileName: "a.swift")
        let s2 = makeSession(fileName: "b.swift")
        let snippet = "let value = compute(input)"
        // Both sessions have entities containing the snippet.
        let e1 = makeEntity(name: "f1", sourceText: "func f1() { let value = compute(input) }")
        let e2 = makeEntity(name: "f2", sourceText: "func f2() { let value = compute(input) }")
        let m1 = makeManaged(session: s1, entities: [e1])
        let m2 = makeManaged(session: s2, entities: [e2])
        let sessions: [UUID: ManagedSession] = [s1.id: m1, s2.id: m2]

        let result = resolver.resolve(
            snippet: snippet,
            sessions: sessions,
            pinnedSessionId: nil,
            activeSessionId: s1.id
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
        let s1 = makeSession(fileName: "a.swift")
        let s2 = makeSession(fileName: "b.swift")
        let m1 = makeManaged(session: s1)
        let m2 = makeManaged(session: s2)
        let sessions: [UUID: ManagedSession] = [s1.id: m1, s2.id: m2]

        let result = resolver.resolve(
            snippet: "completely unrelated snippet text that matches nothing",
            sessions: sessions,
            pinnedSessionId: nil,
            activeSessionId: s1.id
        )

        #expect(result.session === m1)
        #expect(result.confidence == 0)
    }

    // MARK: - No Sessions

    @Test @MainActor
    func noSessionsReturnsNil() {
        let sessions: [UUID: ManagedSession] = [:]

        let result = resolver.resolve(
            snippet: "some long enough snippet text",
            sessions: sessions,
            pinnedSessionId: nil,
            activeSessionId: nil
        )

        #expect(result.session == nil)
        if case .noMatch = result.method {} else {
            Issue.record("Expected .noMatch method")
        }
    }

    @Test @MainActor
    func noActiveSessionAndNoMatchReturnsNil() {
        let s1 = makeSession(fileName: "a.swift")
        let m1 = makeManaged(session: s1)
        let s2 = makeSession(fileName: "b.swift")
        let m2 = makeManaged(session: s2)
        let sessions: [UUID: ManagedSession] = [s1.id: m1, s2.id: m2]

        let result = resolver.resolve(
            snippet: "completely unrelated snippet text that matches nothing",
            sessions: sessions,
            pinnedSessionId: nil,
            activeSessionId: nil // no active session
        )

        #expect(result.session == nil)
    }

    // MARK: - Recency Bonus

    @Test @MainActor
    func recencyBonusBreaksTie() {
        let now = Date()
        let s1 = makeSession(fileName: "old.swift", updatedAt: now.addingTimeInterval(-3600))
        let s2 = makeSession(fileName: "recent.swift", updatedAt: now)
        // Both have no entity match and no file content match, so base score is 0.
        // But s2 gets recency bonus of 10 and s1 gets 5 (if ranked second).
        // With both at 0+bonus, neither reaches threshold (60), so falls back.
        let m1 = makeManaged(session: s1)
        let m2 = makeManaged(session: s2)
        let sessions: [UUID: ManagedSession] = [s1.id: m1, s2.id: m2]

        let result = resolver.resolve(
            snippet: "unrelated long enough snippet text here",
            sessions: sessions,
            pinnedSessionId: nil,
            activeSessionId: nil
        )

        // Both below threshold → no match (no active session set).
        #expect(result.session == nil)
        // But candidates should be ordered by score, s2 first.
        if let first = result.candidates.first {
            #expect(first.session === m2)
        }
    }

    // MARK: - Candidates in Result

    @Test @MainActor
    func candidatesPopulatedForMultipleSessions() {
        let s1 = makeSession(fileName: "a.swift")
        let s2 = makeSession(fileName: "b.swift")
        let entity = makeEntity(
            name: "test",
            sourceText: "func testMethod() { return someValue }"
        )
        let m1 = makeManaged(session: s1, entities: [entity])
        let m2 = makeManaged(session: s2)
        let sessions: [UUID: ManagedSession] = [s1.id: m1, s2.id: m2]

        let result = resolver.resolve(
            snippet: "func testMethod() { return someValue }",
            sessions: sessions,
            pinnedSessionId: nil,
            activeSessionId: nil
        )

        #expect(result.candidates.count == 2)
    }

    // MARK: - Inaccessible Sessions Filtered

    @Test @MainActor
    func inaccessibleSessionsExcludedFromScoring() {
        let s1 = makeSession(fileName: "a.swift")
        let entity = makeEntity(
            name: "test",
            sourceText: "func exactMatchHere() { return 42 }"
        )
        let m1 = makeManaged(session: s1, entities: [entity])
        m1.isFileAccessible = false
        let sessions: [UUID: ManagedSession] = [s1.id: m1]

        let result = resolver.resolve(
            snippet: "func exactMatchHere() { return 42 }",
            sessions: sessions,
            pinnedSessionId: nil,
            activeSessionId: nil
        )

        // No accessible sessions → noMatch.
        #expect(result.session == nil)
    }
}

// MARK: - Resolution Types Tests

@Suite
struct ResolutionMethodTests {

    @Test func descriptionStrings() {
        #expect(ResolutionMethod.pinned.description == "pinned")
        #expect(ResolutionMethod.singleSession.description == "single-session")
        #expect(ResolutionMethod.autoResolved.description == "auto-resolved")
        #expect(ResolutionMethod.noMatch.description == "no-match")
        #expect(ResolutionMethod.fallbackToActive(.snippetTooShort).description == "fallback-to-active(snippet-too-short)")
        #expect(ResolutionMethod.fallbackToActive(.lowConfidence).description == "fallback-to-active(low-confidence)")
        #expect(ResolutionMethod.fallbackToActive(.ambiguous).description == "fallback-to-active(ambiguous)")
        #expect(ResolutionMethod.fallbackToActive(.noSessions).description == "fallback-to-active(no-sessions)")
    }
}

@Suite
struct MatchTypeTests {

    @Test func descriptionStrings() {
        #expect(MatchType.entityContainment.description == "entity-containment")
        #expect(MatchType.normalizedEntityContainment.description == "normalized-entity")
        #expect(MatchType.fileContent.description == "file-content")
        #expect(MatchType.singleSession.description == "single-session")
        #expect(MatchType.noMatch.description == "no-match")
    }
}
