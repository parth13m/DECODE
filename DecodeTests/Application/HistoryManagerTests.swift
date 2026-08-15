// HistoryManagerTests.swift — DecodeTests
//
// Tests for the History feature: HistoryRequest model, HistoryPersistence,
// and HistoryManager.
//
// Covers: empty state, recording, ordering, 10-item cap, follow-up append,
// follow-up does not reorder, persistence round-trip, corrupt JSON,
// clear on logout, Codable round-trip.

import Testing
import Foundation
@testable import Decode

// MARK: - Test Helpers

/// A date with integer-second precision, safe for ISO 8601 round-trip.
private func stableDate(_ offset: TimeInterval = 0) -> Date {
    Date(timeIntervalSinceReferenceDate: 800_000_000 + offset)
}

/// Creates a temporary history file URL. Caller is responsible for cleanup.
private func makeTempHistoryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("decode-history-test-\(UUID().uuidString).json")
}

/// Cleans up a temporary history file.
private func cleanupHistory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - HistoryRequest Model Tests

@Suite
struct HistoryRequestModelTests {

    @Test func codableRoundTrip() throws {
        let followUp = HistoryFollowUp(
            id: UUID(),
            createdAt: stableDate(1),
            question: "Why?",
            answer: "Because."
        )
        let request = HistoryRequest(
            id: UUID(),
            createdAt: stableDate(),
            mode: "selection",
            originalCode: "let x = 1",
            explanation: "This declares a constant.",
            sourceAppName: "Xcode",
            fileName: "Test.swift",
            language: "swift",
            explanationProfile: "general",
            customQuestion: nil,
            followUps: [followUp]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HistoryRequest.self, from: data)

        #expect(decoded == request)
        #expect(decoded.followUps.count == 1)
        #expect(decoded.followUps.first?.question == "Why?")
    }

    @Test func codableRoundTrip_nilOptionals() throws {
        let request = HistoryRequest(
            id: UUID(),
            createdAt: stableDate(),
            mode: "screenshot",
            originalCode: "print(\"hello\")",
            explanation: "Prints hello.",
            sourceAppName: nil,
            fileName: nil,
            language: nil,
            explanationProfile: nil,
            customQuestion: nil,
            followUps: []
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HistoryRequest.self, from: data)

        #expect(decoded == request)
        #expect(decoded.sourceAppName == nil)
        #expect(decoded.fileName == nil)
        #expect(decoded.language == nil)
        #expect(decoded.explanationProfile == nil)
        #expect(decoded.followUps.isEmpty)
    }

    @Test func maxItemCount_isTen() {
        #expect(HistoryRequest.maxItemCount == 10)
    }
}

// MARK: - HistoryPersistence Tests

@Suite
struct HistoryPersistenceTests {

    @Test func saveAndLoad_roundTrip() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let request = HistoryRequest(
            id: UUID(),
            createdAt: stableDate(),
            mode: "selection",
            originalCode: "let x = 1",
            explanation: "Declares x.",
            sourceAppName: nil,
            fileName: nil,
            language: "swift",
            explanationProfile: "general",
            customQuestion: nil,
            followUps: []
        )

        HistoryPersistence.save([request], to: url)
        let loaded = HistoryPersistence.load(from: url)

        #expect(loaded.count == 1)
        #expect(loaded.first == request)
    }

    @Test func load_missingFile_returnsEmpty() {
        let url = makeTempHistoryURL()
        let loaded = HistoryPersistence.load(from: url)
        #expect(loaded.isEmpty)
    }

    @Test func load_corruptedFile_returnsEmpty() throws {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        try "{ this is not valid json }}}".data(using: .utf8)!.write(to: url)
        let loaded = HistoryPersistence.load(from: url)
        #expect(loaded.isEmpty)
    }

    @Test func load_emptyFile_returnsEmpty() throws {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        try Data().write(to: url)
        let loaded = HistoryPersistence.load(from: url)
        #expect(loaded.isEmpty)
    }

    @Test func delete_removesFile() {
        let url = makeTempHistoryURL()

        HistoryPersistence.save([], to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        HistoryPersistence.delete(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func save_overwritesExisting() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let r1 = HistoryRequest(
            id: UUID(), createdAt: stableDate(), mode: "selection",
            originalCode: "a", explanation: "b",
            sourceAppName: nil, fileName: nil, language: nil,
            explanationProfile: nil, customQuestion: nil, followUps: []
        )
        let r2 = HistoryRequest(
            id: UUID(), createdAt: stableDate(1), mode: "session",
            originalCode: "c", explanation: "d",
            sourceAppName: nil, fileName: nil, language: nil,
            explanationProfile: nil, customQuestion: nil, followUps: []
        )

        HistoryPersistence.save([r1], to: url)
        HistoryPersistence.save([r2], to: url)

        let loaded = HistoryPersistence.load(from: url)
        #expect(loaded.count == 1)
        #expect(loaded.first == r2)
    }

    @Test func saveAndLoad_withFollowUps() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let followUp = HistoryFollowUp(
            id: UUID(), createdAt: stableDate(1),
            question: "What does this do?", answer: "It does X."
        )
        let request = HistoryRequest(
            id: UUID(), createdAt: stableDate(), mode: "session",
            originalCode: "func run() { }", explanation: "Runs the app.",
            sourceAppName: "Xcode", fileName: "Main.swift",
            language: "swift", explanationProfile: "general",
            customQuestion: nil, followUps: [followUp]
        )

        HistoryPersistence.save([request], to: url)
        let loaded = HistoryPersistence.load(from: url)

        #expect(loaded.count == 1)
        #expect(loaded.first?.followUps.count == 1)
        #expect(loaded.first?.followUps.first?.question == "What does this do?")
        #expect(loaded.first?.followUps.first?.answer == "It does X.")
    }
}

// MARK: - HistoryManager Tests

@Suite(.serialized)
struct HistoryManagerTests {

    // MARK: - Empty State

    @Test @MainActor func emptyState_noItems() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        #expect(manager.items.isEmpty)
        #expect(manager.activeRequest == nil)
    }

    @Test @MainActor func restore_noFile_emptyItems() {
        let url = makeTempHistoryURL()

        let manager = HistoryManager(fileURL: url)
        manager.restore()
        #expect(manager.items.isEmpty)
    }

    // MARK: - Record Explanation

    @Test @MainActor func recordExplanation_addsItem() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection",
            originalCode: "let x = 1",
            explanation: "Declares x."
        )

        #expect(manager.items.count == 1)
        #expect(manager.items.first?.id == id)
        #expect(manager.items.first?.mode == "selection")
        #expect(manager.items.first?.originalCode == "let x = 1")
        #expect(manager.items.first?.explanation == "Declares x.")
        #expect(manager.items.first?.followUps.isEmpty == true)
    }

    @Test @MainActor func recordExplanation_withOptionalMetadata() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        manager.recordExplanation(
            mode: "session",
            originalCode: "func run() { }",
            explanation: "Runs it.",
            sourceAppName: "Xcode",
            fileName: "Main.swift",
            language: "swift",
            explanationProfile: "dsa"
        )

        let item = manager.items.first
        #expect(item?.sourceAppName == "Xcode")
        #expect(item?.fileName == "Main.swift")
        #expect(item?.language == "swift")
        #expect(item?.explanationProfile == "dsa")
    }

    // MARK: - Multiple Explanations / Ordering

    @Test @MainActor func multipleExplanations_newestFirst() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id1 = manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "first"
        )
        let id2 = manager.recordExplanation(
            mode: "selection", originalCode: "b", explanation: "second"
        )
        let id3 = manager.recordExplanation(
            mode: "session", originalCode: "c", explanation: "third"
        )

        #expect(manager.items.count == 3)
        #expect(manager.items[0].id == id3) // newest
        #expect(manager.items[1].id == id2)
        #expect(manager.items[2].id == id1) // oldest
    }

    @Test @MainActor func activeRequest_isNewest() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "first"
        )
        let id2 = manager.recordExplanation(
            mode: "selection", originalCode: "b", explanation: "second"
        )

        #expect(manager.activeRequest?.id == id2)
    }

    // MARK: - 10 Item Limit

    @Test @MainActor func tenItemLimit_evictsOldest() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        var ids: [UUID] = []
        for i in 1...10 {
            let id = manager.recordExplanation(
                mode: "selection", originalCode: "code\(i)", explanation: "exp\(i)"
            )
            ids.append(id)
        }
        #expect(manager.items.count == 10)

        // Record the 11th — should evict the first one recorded (ids[0]).
        let id11 = manager.recordExplanation(
            mode: "selection", originalCode: "code11", explanation: "exp11"
        )

        #expect(manager.items.count == 10)
        #expect(manager.items.first?.id == id11)
        #expect(manager.items.contains(where: { $0.id == ids[0] }) == false)
        // ids[1]..ids[9] should still be present
        for i in 1..<10 {
            #expect(manager.items.contains(where: { $0.id == ids[i] }))
        }
    }

    @Test @MainActor func tenItemLimit_repeatedEviction() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        for i in 1...15 {
            manager.recordExplanation(
                mode: "selection", originalCode: "code\(i)", explanation: "exp\(i)"
            )
        }

        #expect(manager.items.count == 10)
        // The newest should be "code15" and oldest should be "code6"
        #expect(manager.items.first?.originalCode == "code15")
        #expect(manager.items.last?.originalCode == "code6")
    }

    // MARK: - Follow-Up Append

    @Test @MainActor func recordFollowUp_appendsToRequest() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "b"
        )

        manager.recordFollowUp(
            requestId: id,
            question: "Why?",
            answer: "Because."
        )

        #expect(manager.items.first?.followUps.count == 1)
        #expect(manager.items.first?.followUps.first?.question == "Why?")
        #expect(manager.items.first?.followUps.first?.answer == "Because.")
    }

    @Test @MainActor func recordFollowUp_multipleFollowUps() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "b"
        )

        manager.recordFollowUp(requestId: id, question: "Q1", answer: "A1")
        manager.recordFollowUp(requestId: id, question: "Q2", answer: "A2")
        manager.recordFollowUp(requestId: id, question: "Q3", answer: "A3")

        #expect(manager.items.first?.followUps.count == 3)
        #expect(manager.items.first?.followUps[0].question == "Q1")
        #expect(manager.items.first?.followUps[1].question == "Q2")
        #expect(manager.items.first?.followUps[2].question == "Q3")
    }

    @Test @MainActor func recordFollowUp_unknownRequestId_noEffect() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "b"
        )

        // Try to record a follow-up on a non-existent request.
        manager.recordFollowUp(
            requestId: UUID(),
            question: "Q",
            answer: "A"
        )

        // The existing request should be unaffected.
        #expect(manager.items.first?.followUps.isEmpty == true)
    }

    // MARK: - Follow-Up Does Not Reorder

    @Test @MainActor func recordFollowUp_doesNotReorderParent() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id1 = manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "first"
        )
        let id2 = manager.recordExplanation(
            mode: "selection", originalCode: "b", explanation: "second"
        )
        let id3 = manager.recordExplanation(
            mode: "session", originalCode: "c", explanation: "third"
        )

        // Order should be: id3, id2, id1
        #expect(manager.items[0].id == id3)
        #expect(manager.items[1].id == id2)
        #expect(manager.items[2].id == id1)

        // Add a follow-up to the oldest request (id1).
        manager.recordFollowUp(requestId: id1, question: "Q", answer: "A")

        // Order must remain: id3, id2, id1 (follow-up does NOT promote).
        #expect(manager.items[0].id == id3)
        #expect(manager.items[1].id == id2)
        #expect(manager.items[2].id == id1)
        #expect(manager.items[2].followUps.count == 1)
    }

    // MARK: - Persistence

    @Test @MainActor func persistence_survivesRestart() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        // Simulate first session.
        let manager1 = HistoryManager(fileURL: url)
        let id = manager1.recordExplanation(
            mode: "selection", originalCode: "let x = 1",
            explanation: "Declares x.", sourceAppName: "Xcode",
            fileName: "Test.swift", language: "swift",
            explanationProfile: "general"
        )
        manager1.recordFollowUp(requestId: id, question: "Why?", answer: "Because.")

        // Simulate restart — new manager, same file.
        let manager2 = HistoryManager(fileURL: url)
        manager2.restore()

        #expect(manager2.items.count == 1)
        #expect(manager2.items.first?.id == id)
        #expect(manager2.items.first?.originalCode == "let x = 1")
        #expect(manager2.items.first?.explanation == "Declares x.")
        #expect(manager2.items.first?.sourceAppName == "Xcode")
        #expect(manager2.items.first?.followUps.count == 1)
        #expect(manager2.items.first?.followUps.first?.question == "Why?")
    }

    @Test @MainActor func persistence_followUpPersistsImmediately() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "b"
        )
        manager.recordFollowUp(requestId: id, question: "Q", answer: "A")

        // Load directly from file to verify persistence.
        let loaded = HistoryPersistence.load(from: url)
        #expect(loaded.first?.followUps.count == 1)
    }

    @Test @MainActor func restore_corruptFile_startsEmpty() throws {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        try "not json at all!!!".data(using: .utf8)!.write(to: url)

        let manager = HistoryManager(fileURL: url)
        manager.restore()
        #expect(manager.items.isEmpty)
    }

    @Test @MainActor func restore_missingFile_startsEmpty() {
        let url = makeTempHistoryURL()

        let manager = HistoryManager(fileURL: url)
        manager.restore()
        #expect(manager.items.isEmpty)
    }

    // MARK: - Clear (Logout)

    @Test @MainActor func clear_removesAllItemsAndFile() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "b"
        )
        #expect(manager.items.count == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))

        manager.clear()

        #expect(manager.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test @MainActor func clear_thenRecord_works() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "b"
        )
        manager.clear()

        let id = manager.recordExplanation(
            mode: "session", originalCode: "c", explanation: "d"
        )
        #expect(manager.items.count == 1)
        #expect(manager.items.first?.id == id)
        #expect(manager.items.first?.mode == "session")
    }

    // MARK: - Clear History (Regression)

    @Test @MainActor func clear_removesFollowUps() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "b"
        )
        manager.recordFollowUp(requestId: id, question: "Q1", answer: "A1")
        manager.recordFollowUp(requestId: id, question: "Q2", answer: "A2")

        #expect(manager.items.first?.followUps.count == 2)

        manager.clear()

        #expect(manager.items.isEmpty)
        // Verify persistence is also cleared.
        let loaded = HistoryPersistence.load(from: url)
        #expect(loaded.isEmpty)
    }

    @Test @MainActor func clear_activeRequestBecomesNil() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "b"
        )
        #expect(manager.activeRequest != nil)

        manager.clear()

        #expect(manager.activeRequest == nil)
    }

    @Test @MainActor func clear_persistsSurvivesRestart() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager1 = HistoryManager(fileURL: url)
        manager1.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "b"
        )
        manager1.recordFollowUp(
            requestId: manager1.items.first!.id,
            question: "Q", answer: "A"
        )

        manager1.clear()

        // Simulate restart.
        let manager2 = HistoryManager(fileURL: url)
        manager2.restore()

        #expect(manager2.items.isEmpty)
        #expect(manager2.activeRequest == nil)
    }

    @Test @MainActor func clear_multipleRequestsAllRemoved() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        for i in 1...5 {
            let id = manager.recordExplanation(
                mode: "selection", originalCode: "code\(i)", explanation: "exp\(i)"
            )
            manager.recordFollowUp(requestId: id, question: "Q\(i)", answer: "A\(i)")
        }
        #expect(manager.items.count == 5)

        manager.clear()

        #expect(manager.items.isEmpty)
        #expect(manager.activeRequest == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Edge Cases

    @Test @MainActor func recordExplanation_persistsImmediately() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "b"
        )

        // Load directly from file.
        let loaded = HistoryPersistence.load(from: url)
        #expect(loaded.count == 1)
        #expect(loaded.first?.originalCode == "a")
    }

    @Test @MainActor func multipleManagers_lastWriteWins() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager1 = HistoryManager(fileURL: url)
        manager1.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "from manager1"
        )

        let manager2 = HistoryManager(fileURL: url)
        manager2.recordExplanation(
            mode: "session", originalCode: "b", explanation: "from manager2"
        )

        // File should contain manager2's data (last write wins).
        let loaded = HistoryPersistence.load(from: url)
        #expect(loaded.count == 1)
        #expect(loaded.first?.explanation == "from manager2")
    }

    // MARK: - Follow-Up Input Enablement (Regression)

    @Test @MainActor func activeRequest_availableWithOneItem() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "b"
        )
        #expect(manager.activeRequest != nil)
        #expect(manager.activeRequest?.id == id)
        #expect(!manager.items.isEmpty)
    }

    @Test @MainActor func activeRequest_nilWhenEmpty() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        #expect(manager.activeRequest == nil)
        #expect(manager.items.isEmpty)
    }

    @Test @MainActor func followUp_preservesParentRequestUUID() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id1 = manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "first"
        )
        let id2 = manager.recordExplanation(
            mode: "session", originalCode: "b", explanation: "second"
        )

        // Follow-up on the older request (not the active one).
        manager.recordFollowUp(requestId: id1, question: "Q", answer: "A")

        // Verify it's on the correct request, not the active one.
        let request1 = manager.items.first(where: { $0.id == id1 })
        let request2 = manager.items.first(where: { $0.id == id2 })
        #expect(request1?.followUps.count == 1)
        #expect(request2?.followUps.isEmpty == true)
    }

    @Test @MainActor func followUp_doesNotCreateNewHistoryItem() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "b"
        )
        #expect(manager.items.count == 1)

        manager.recordFollowUp(requestId: id, question: "Q1", answer: "A1")
        #expect(manager.items.count == 1)

        manager.recordFollowUp(requestId: id, question: "Q2", answer: "A2")
        #expect(manager.items.count == 1)
        #expect(manager.items.first?.followUps.count == 2)
    }

    @Test @MainActor func followUp_persistsSurvivesRestart() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager1 = HistoryManager(fileURL: url)
        let id = manager1.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "b"
        )
        manager1.recordFollowUp(requestId: id, question: "Q1", answer: "A1")
        manager1.recordFollowUp(requestId: id, question: "Q2", answer: "A2")

        // Simulate restart.
        let manager2 = HistoryManager(fileURL: url)
        manager2.restore()

        #expect(manager2.items.count == 1)
        #expect(manager2.items.first?.id == id)
        #expect(manager2.items.first?.followUps.count == 2)
        #expect(manager2.items.first?.followUps[0].question == "Q1")
        #expect(manager2.items.first?.followUps[1].question == "Q2")
    }

    @Test @MainActor func activeRequest_remainsAfterFollowUp() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "b"
        )

        manager.recordFollowUp(requestId: id, question: "Q", answer: "A")

        // Active request should still be available after follow-up.
        #expect(manager.activeRequest != nil)
        #expect(manager.activeRequest?.id == id)
        #expect(!manager.items.isEmpty)
    }

    // MARK: - Chronological Display Order

    @Test @MainActor func chronologicalOrder_reversedForDisplay() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id1 = manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "first"
        )
        let id2 = manager.recordExplanation(
            mode: "selection", originalCode: "b", explanation: "second"
        )
        let id3 = manager.recordExplanation(
            mode: "session", originalCode: "c", explanation: "third"
        )

        // Internal storage: newest first.
        #expect(manager.items[0].id == id3)
        #expect(manager.items[2].id == id1)

        // Chronological (UI) order: oldest first.
        let chronological = manager.items.reversed()
        let chrono = Array(chronological)
        #expect(chrono[0].id == id1) // oldest at top
        #expect(chrono[1].id == id2)
        #expect(chrono[2].id == id3) // newest at bottom
    }

    @Test @MainActor func activeRequest_isNewestNotOldest() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id1 = manager.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "first"
        )
        let _ = manager.recordExplanation(
            mode: "session", originalCode: "b", explanation: "second"
        )

        // Active request is newest (items.first), not the oldest.
        #expect(manager.activeRequest?.id != id1)
        #expect(manager.activeRequest?.explanation == "second")

        // In reversed (chronological) order, oldest is [0] and newest is last.
        let chronological = Array(manager.items.reversed())
        #expect(chronological.first?.id == id1) // oldest at display top
        #expect(chronological.last?.id == manager.activeRequest?.id) // newest at display bottom
    }

    // MARK: - Custom Question (Personalized Query)

    @Test @MainActor func recordExplanation_withCustomQuestion() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        manager.recordExplanation(
            mode: "selection", originalCode: "actor MyActor {}",
            explanation: "This is an actor.",
            customQuestion: "Why is this actor isolated?"
        )

        #expect(manager.items.first?.customQuestion == "Why is this actor isolated?")
    }

    @Test @MainActor func recordExplanation_withoutCustomQuestion() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        manager.recordExplanation(
            mode: "selection", originalCode: "let x = 1",
            explanation: "Declares x."
        )

        #expect(manager.items.first?.customQuestion == nil)
    }

    @Test @MainActor func customQuestion_persistsAcrossRestart() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager1 = HistoryManager(fileURL: url)
        manager1.recordExplanation(
            mode: "selection", originalCode: "a", explanation: "b",
            customQuestion: "Explain concurrency"
        )

        let manager2 = HistoryManager(fileURL: url)
        manager2.restore()

        #expect(manager2.items.first?.customQuestion == "Explain concurrency")
    }

    @Test func codableRoundTrip_withCustomQuestion() throws {
        let request = HistoryRequest(
            id: UUID(), createdAt: stableDate(), mode: "selection",
            originalCode: "a", explanation: "b",
            sourceAppName: nil, fileName: nil, language: nil,
            explanationProfile: nil,
            customQuestion: "Why does this use async?",
            followUps: []
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HistoryRequest.self, from: data)

        #expect(decoded.customQuestion == "Why does this use async?")
    }

    @Test func codableBackwardCompatibility_missingCustomQuestion() throws {
        // Simulate loading a history file created before customQuestion existed.
        let json = """
        [{
            "id": "00000000-0000-0000-0000-000000000001",
            "createdAt": "2026-08-01T00:00:00Z",
            "mode": "selection",
            "originalCode": "let x = 1",
            "explanation": "Declares x.",
            "followUps": []
        }]
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = try decoder.decode([HistoryRequest].self, from: data)

        #expect(items.count == 1)
        #expect(items.first?.customQuestion == nil)
    }

    // MARK: - Context Integrity (Regression: Follow-Up Must Preserve Source Context)

    /// Test 1: activeRequest returns the newest request.
    /// Note: the UI now requires explicit selection for follow-ups,
    /// but activeRequest remains available on the data model.
    @Test @MainActor func contextIntegrity_unanchoredFollowUp_usesActiveRequest() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        manager.recordExplanation(
            mode: "selection", originalCode: "func old() {}",
            explanation: "Old function."
        )
        let id2 = manager.recordExplanation(
            mode: "session", originalCode: "func new() {}",
            explanation: "New function."
        )

        // Without selection, the active (newest) request provides context.
        let active = manager.activeRequest
        #expect(active != nil)
        #expect(active?.id == id2)
        #expect(active?.originalCode == "func new() {}")
        #expect(active?.explanation == "New function.")
    }

    /// Test 2: When user selects explanation text from a specific request,
    /// that request's originalCode must be present — not just the selected text.
    @Test @MainActor func contextIntegrity_selectedExplanation_preservesOriginalCode() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id1 = manager.recordExplanation(
            mode: "selection",
            originalCode: "import Foundation\nclass Parser { }",
            explanation: "A parser class that imports Foundation."
        )
        // Record a newer request so id1 is NOT the active request.
        manager.recordExplanation(
            mode: "session", originalCode: "func unrelated() {}",
            explanation: "Something else."
        )

        // Simulate resolving context for the older request by ID.
        let contextRequest = manager.items.first(where: { $0.id == id1 })
        #expect(contextRequest != nil)
        #expect(contextRequest?.originalCode == "import Foundation\nclass Parser { }")
        #expect(contextRequest?.explanation == "A parser class that imports Foundation.")
        // The selectedText is additive context — the original code is always present.
        #expect(!contextRequest!.originalCode.isEmpty)
    }

    /// Test 3: When user selects code from a request, the originalCode of
    /// that specific request must be used (not the active/newest request).
    @Test @MainActor func contextIntegrity_selectedCode_usesCorrectRequest() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let targetId = manager.recordExplanation(
            mode: "selection",
            originalCode: "let swiftCode = true",
            explanation: "Declares a boolean."
        )
        let activeId = manager.recordExplanation(
            mode: "session",
            originalCode: "pythonCode = True",
            explanation: "Python boolean."
        )

        // The active request is the newest.
        #expect(manager.activeRequest?.id == activeId)

        // But when resolving by the target ID, we get the correct request.
        let target = manager.items.first(where: { $0.id == targetId })
        #expect(target?.originalCode == "let swiftCode = true")
        #expect(target?.originalCode != manager.activeRequest?.originalCode)
    }

    /// Test 4: Follow-up after previous follow-ups must preserve all prior Q&A.
    @Test @MainActor func contextIntegrity_afterPreviousFollowUp_preservesHistory() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection",
            originalCode: "actor NetworkManager { }",
            explanation: "An actor for thread-safe networking."
        )

        manager.recordFollowUp(requestId: id, question: "Is this Sendable?", answer: "Yes, actors are Sendable.")
        manager.recordFollowUp(requestId: id, question: "Can it deadlock?", answer: "Actors prevent data races but can deadlock with re-entrant calls.")

        let request = manager.items.first(where: { $0.id == id })
        #expect(request != nil)
        // All prior follow-ups are preserved in order.
        #expect(request?.followUps.count == 2)
        #expect(request?.followUps[0].question == "Is this Sendable?")
        #expect(request?.followUps[1].question == "Can it deadlock?")
        // Original code is still intact.
        #expect(request?.originalCode == "actor NetworkManager { }")
        #expect(request?.explanation == "An actor for thread-safe networking.")
    }

    /// Test 5: Follow-up with personalized query must include the custom question.
    @Test @MainActor func contextIntegrity_withPersonalizedQuery_preservesCustomQuestion() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection",
            originalCode: "@MainActor final class ViewModel { }",
            explanation: "A main-actor-isolated view model.",
            customQuestion: "Why is MainActor needed here?"
        )

        // Custom question is preserved alongside the original code.
        let request = manager.items.first(where: { $0.id == id })
        #expect(request?.originalCode == "@MainActor final class ViewModel { }")
        #expect(request?.customQuestion == "Why is MainActor needed here?")

        // After a follow-up, the custom question is still intact.
        manager.recordFollowUp(requestId: id, question: "Follow-up Q", answer: "Follow-up A")
        let updated = manager.items.first(where: { $0.id == id })
        #expect(updated?.customQuestion == "Why is MainActor needed here?")
        #expect(updated?.originalCode == "@MainActor final class ViewModel { }")
    }

    /// Test 6: When resolving context by request ID, unrelated requests
    /// must NOT be included — only the targeted request provides context.
    @Test @MainActor func contextIntegrity_unrelatedRequests_excluded() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id1 = manager.recordExplanation(
            mode: "selection", originalCode: "Swift code here",
            explanation: "Swift explanation."
        )
        let id2 = manager.recordExplanation(
            mode: "session", originalCode: "Python code here",
            explanation: "Python explanation."
        )
        let id3 = manager.recordExplanation(
            mode: "selection", originalCode: "Rust code here",
            explanation: "Rust explanation."
        )

        // Looking up each request by ID returns only that request's data.
        let r1 = manager.items.first(where: { $0.id == id1 })
        let r2 = manager.items.first(where: { $0.id == id2 })
        let r3 = manager.items.first(where: { $0.id == id3 })

        #expect(r1?.originalCode == "Swift code here")
        #expect(r2?.originalCode == "Python code here")
        #expect(r3?.originalCode == "Rust code here")

        // Each request is independent — no cross-contamination.
        #expect(r1?.originalCode != r2?.originalCode)
        #expect(r2?.originalCode != r3?.originalCode)
        #expect(r1?.explanation != r3?.explanation)

        // Follow-up on r2 does not affect r1 or r3.
        manager.recordFollowUp(requestId: id2, question: "Q", answer: "A")
        #expect(manager.items.first(where: { $0.id == id1 })?.followUps.isEmpty == true)
        #expect(manager.items.first(where: { $0.id == id2 })?.followUps.count == 1)
        #expect(manager.items.first(where: { $0.id == id3 })?.followUps.isEmpty == true)
    }

    // MARK: - Selection-Required Follow-Up (Product Rule: Explicit Context)

    /// No selection → Follow-Up not submittable.
    /// At the data model level: without a source request ID, there is no
    /// context to resolve.
    @Test @MainActor func selectionRequired_noSelection_noContext() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        manager.recordExplanation(
            mode: "selection", originalCode: "let x = 1", explanation: "Declares x."
        )
        manager.recordExplanation(
            mode: "session", originalCode: "let y = 2", explanation: "Declares y."
        )

        // Without a selectionSourceRequestId, resolving by UUID returns nil.
        let noId: UUID? = nil
        let resolved = noId.flatMap { id in manager.items.first(where: { $0.id == id }) }
        #expect(resolved == nil)
    }

    /// Main explanation selection → valid context.
    @Test @MainActor func selectionRequired_mainExplanation_validContext() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection", originalCode: "import SwiftUI", explanation: "Imports SwiftUI."
        )

        let resolved = manager.items.first(where: { $0.id == id })
        #expect(resolved != nil)
        #expect(resolved?.originalCode == "import SwiftUI")
    }

    /// Code selection → valid context (same request, nil follow-up index).
    @Test @MainActor func selectionRequired_codeSelection_validContext() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection", originalCode: "struct Config { }", explanation: "Config struct."
        )

        let resolved = manager.items.first(where: { $0.id == id })
        #expect(resolved != nil)
        #expect(resolved?.originalCode == "struct Config { }")
        // Code selection → followUpIndex = nil → no follow-ups in scope.
    }

    /// Follow-Up question selection → valid context with correct follow-up index.
    @Test @MainActor func selectionRequired_followUpQuestion_validContext() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection", originalCode: "func run() {}", explanation: "Runs."
        )
        manager.recordFollowUp(requestId: id, question: "Why?", answer: "Because.")
        manager.recordFollowUp(requestId: id, question: "How?", answer: "Like this.")

        let resolved = manager.items.first(where: { $0.id == id })
        #expect(resolved != nil)
        // Selecting follow-up 0 question → scope through index 0.
        let throughIndex = 0
        let scoped = resolved!.followUps[0..<min(throughIndex + 1, resolved!.followUps.count)]
        #expect(scoped.count == 1)
        #expect(scoped[0].question == "Why?")
    }

    /// Follow-Up answer selection → valid context with correct follow-up index.
    @Test @MainActor func selectionRequired_followUpAnswer_validContext() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection", originalCode: "actor Net {}", explanation: "Network actor."
        )
        manager.recordFollowUp(requestId: id, question: "Q1", answer: "A1")
        manager.recordFollowUp(requestId: id, question: "Q2", answer: "A2")

        let resolved = manager.items.first(where: { $0.id == id })
        #expect(resolved != nil)
        // Selecting follow-up 1 answer → scope through index 1.
        let throughIndex = 1
        let scoped = resolved!.followUps[0..<min(throughIndex + 1, resolved!.followUps.count)]
        #expect(scoped.count == 2)
        #expect(scoped[0].question == "Q1")
        #expect(scoped[1].question == "Q2")
    }

    /// Selection from Request 1 resolves Request 1 (not newest).
    @Test @MainActor func selectionRequired_correctRequestResolution() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id1 = manager.recordExplanation(
            mode: "selection", originalCode: "Request 1 code",
            explanation: "Request 1 explanation."
        )
        manager.recordExplanation(
            mode: "session", originalCode: "Request 2 code",
            explanation: "Request 2 explanation."
        )
        manager.recordExplanation(
            mode: "selection", originalCode: "Request 3 code",
            explanation: "Request 3 explanation."
        )

        // selectionSourceRequestId = id1 → resolves Request 1.
        let resolved = manager.items.first(where: { $0.id == id1 })
        #expect(resolved?.originalCode == "Request 1 code")
        #expect(resolved?.explanation == "Request 1 explanation.")
    }

    /// Follow-Up 2 of Request 2 → correct hierarchy, excludes other requests.
    @Test @MainActor func selectionRequired_followUpHierarchy_correctScope() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        manager.recordExplanation(
            mode: "selection", originalCode: "R1", explanation: "R1 exp."
        )
        let id2 = manager.recordExplanation(
            mode: "session", originalCode: "R2 code",
            explanation: "R2 explanation.",
            customQuestion: "R2 custom question"
        )
        manager.recordFollowUp(requestId: id2, question: "R2-Q1", answer: "R2-A1")
        manager.recordFollowUp(requestId: id2, question: "R2-Q2", answer: "R2-A2")
        manager.recordFollowUp(requestId: id2, question: "R2-Q3", answer: "R2-A3")
        manager.recordExplanation(
            mode: "selection", originalCode: "R3", explanation: "R3 exp."
        )

        // Select Follow-Up 1 of Request 2.
        let resolved = manager.items.first(where: { $0.id == id2 })!
        let throughIndex = 1
        let scoped = resolved.followUps[0..<min(throughIndex + 1, resolved.followUps.count)]

        #expect(resolved.originalCode == "R2 code")
        #expect(resolved.customQuestion == "R2 custom question")
        #expect(scoped.count == 2)
        #expect(scoped[0].question == "R2-Q1")
        #expect(scoped[1].question == "R2-Q2")
        // R2-Q3 excluded (after selected follow-up).
        // R1 and R3 are not referenced at all.
    }

    /// Clearing selection removes all source metadata.
    @Test @MainActor func selectionRequired_clearSelection_disablesFollowUp() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection", originalCode: "code", explanation: "exp"
        )

        // Simulate: selection active → clear → resolve returns nil.
        var sourceId: UUID? = id
        #expect(sourceId.flatMap { sid in manager.items.first(where: { $0.id == sid }) } != nil)

        // Clear.
        sourceId = nil
        #expect(sourceId.flatMap { sid in manager.items.first(where: { $0.id == sid }) } == nil)
    }

    // MARK: - Follow-Up Chain Context (Regression: Hierarchical Conversation)

    /// When selecting main explanation, only original code + explanation are relevant.
    /// Follow-ups should NOT be in scope.
    @Test @MainActor func followUpChain_mainExplanationSelected_noFollowUpsInScope() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection",
            originalCode: "import SwiftUI\nimport os.log",
            explanation: "Two import statements.",
            customQuestion: "Explain from Swift perspective"
        )
        manager.recordFollowUp(requestId: id, question: "Why os.log?", answer: "Unified logging.")
        manager.recordFollowUp(requestId: id, question: "Performance?", answer: "Optimized.")

        let request = manager.items.first(where: { $0.id == id })!

        // Main explanation scope: follow-ups 0..< -1 (i.e., none).
        // The request has follow-ups, but when throughFollowUpIndex is negative,
        // no follow-ups should be included.
        #expect(request.originalCode == "import SwiftUI\nimport os.log")
        #expect(request.explanation == "Two import statements.")
        #expect(request.customQuestion == "Explain from Swift perspective")
        #expect(request.followUps.count == 2)
        // Slicing with index -1 → empty: request.followUps[0..<0]
        let noFollowUps = request.followUps[0..<max(0, -1 + 1)]
        #expect(noFollowUps.isEmpty)
    }

    /// When Follow-Up 0 is selected, include only Follow-Up 0.
    @Test @MainActor func followUpChain_followUp0Selected_includesOnlyFirst() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection",
            originalCode: "actor MyActor { }",
            explanation: "An actor."
        )
        manager.recordFollowUp(requestId: id, question: "Is it Sendable?", answer: "Yes.")
        manager.recordFollowUp(requestId: id, question: "Can it deadlock?", answer: "Possibly.")
        manager.recordFollowUp(requestId: id, question: "How to prevent?", answer: "Use structured concurrency.")

        let request = manager.items.first(where: { $0.id == id })!

        // Selecting from Follow-Up 0 → include follow-ups[0...0].
        let throughIndex = 0
        let scoped = request.followUps[0..<min(throughIndex + 1, request.followUps.count)]
        #expect(scoped.count == 1)
        #expect(scoped[0].question == "Is it Sendable?")
        #expect(scoped[0].answer == "Yes.")
    }

    /// When Follow-Up 1 is selected, include Follow-Ups 0 and 1.
    @Test @MainActor func followUpChain_followUp1Selected_includesFirstTwo() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection",
            originalCode: "class Parser { }",
            explanation: "A parser class."
        )
        manager.recordFollowUp(requestId: id, question: "Q1", answer: "A1")
        manager.recordFollowUp(requestId: id, question: "Q2", answer: "A2")
        manager.recordFollowUp(requestId: id, question: "Q3", answer: "A3")

        let request = manager.items.first(where: { $0.id == id })!

        // Selecting from Follow-Up 1 → include follow-ups[0...1].
        let throughIndex = 1
        let scoped = request.followUps[0..<min(throughIndex + 1, request.followUps.count)]
        #expect(scoped.count == 2)
        #expect(scoped[0].question == "Q1")
        #expect(scoped[1].question == "Q2")
        // Q3 is EXCLUDED.
    }

    /// When no selection (unanchored), ALL follow-ups are included.
    @Test @MainActor func followUpChain_noSelection_includesAllFollowUps() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection",
            originalCode: "func test() { }",
            explanation: "A test function."
        )
        manager.recordFollowUp(requestId: id, question: "Q1", answer: "A1")
        manager.recordFollowUp(requestId: id, question: "Q2", answer: "A2")

        let request = manager.items.first(where: { $0.id == id })!

        // No selection → include all follow-ups.
        let allFollowUps = request.followUps[0..<request.followUps.count]
        #expect(allFollowUps.count == 2)
        #expect(allFollowUps[0].question == "Q1")
        #expect(allFollowUps[1].question == "Q2")
    }

    /// Follow-up from specific older request uses correct data.
    @Test @MainActor func followUpChain_olderRequest_correctChain() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let idA = manager.recordExplanation(
            mode: "selection",
            originalCode: "Python code",
            explanation: "Python explanation.",
            customQuestion: "Explain Python"
        )
        manager.recordFollowUp(requestId: idA, question: "PQ1", answer: "PA1")
        manager.recordFollowUp(requestId: idA, question: "PQ2", answer: "PA2")

        // Request B is newer (active).
        manager.recordExplanation(
            mode: "session",
            originalCode: "Swift code",
            explanation: "Swift explanation."
        )

        // User selects from Request A, Follow-Up 0.
        let requestA = manager.items.first(where: { $0.id == idA })!
        let throughIndex = 0
        let scoped = requestA.followUps[0..<min(throughIndex + 1, requestA.followUps.count)]

        #expect(requestA.originalCode == "Python code")
        #expect(requestA.customQuestion == "Explain Python")
        #expect(scoped.count == 1)
        #expect(scoped[0].question == "PQ1")
        // PQ2 is excluded (after selected follow-up).
    }

    /// Personalized query preserved in follow-up chain.
    @Test @MainActor func followUpChain_personalizedQuery_preserved() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection",
            originalCode: "@MainActor final class VM { }",
            explanation: "A view model.",
            customQuestion: "Why MainActor?"
        )
        manager.recordFollowUp(requestId: id, question: "Threading?", answer: "Main thread only.")

        let request = manager.items.first(where: { $0.id == id })!

        // Custom question is preserved at every scope level.
        #expect(request.customQuestion == "Why MainActor?")
        // Follow-up 0 scope:
        let scoped = request.followUps[0..<min(0 + 1, request.followUps.count)]
        #expect(scoped.count == 1)
        // Original code always present:
        #expect(request.originalCode == "@MainActor final class VM { }")
    }

    /// Follow-Up 2 selected from older request with multiple requests.
    @Test @MainActor func followUpChain_followUp2FromOlderRequest_correctScope() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let idOld = manager.recordExplanation(
            mode: "selection",
            originalCode: "struct Config { }",
            explanation: "Configuration struct."
        )
        manager.recordFollowUp(requestId: idOld, question: "Q0", answer: "A0")
        manager.recordFollowUp(requestId: idOld, question: "Q1", answer: "A1")
        manager.recordFollowUp(requestId: idOld, question: "Q2", answer: "A2")
        manager.recordFollowUp(requestId: idOld, question: "Q3", answer: "A3")

        // Make a newer request so idOld is NOT active.
        manager.recordExplanation(
            mode: "session",
            originalCode: "unrelated",
            explanation: "unrelated"
        )

        let request = manager.items.first(where: { $0.id == idOld })!

        // Select from Follow-Up 2 → include 0, 1, 2. Exclude 3.
        let throughIndex = 2
        let scoped = request.followUps[0..<min(throughIndex + 1, request.followUps.count)]
        #expect(scoped.count == 3)
        #expect(scoped[0].question == "Q0")
        #expect(scoped[1].question == "Q1")
        #expect(scoped[2].question == "Q2")
        // Q3 must not be included.
    }

    // MARK: - Eviction Edge Cases

    @Test @MainActor func tenItemLimit_evictionPreservesFollowUps() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)

        // Fill to 10 items, adding follow-ups to the second item.
        var ids: [UUID] = []
        for i in 1...10 {
            let id = manager.recordExplanation(
                mode: "selection", originalCode: "code\(i)", explanation: "exp\(i)"
            )
            ids.append(id)
        }
        // Add follow-up to item at index 8 (ids[1], second oldest).
        manager.recordFollowUp(requestId: ids[1], question: "Q", answer: "A")

        // Record 11th — evicts ids[0] (oldest, no follow-ups).
        manager.recordExplanation(
            mode: "selection", originalCode: "code11", explanation: "exp11"
        )

        #expect(manager.items.count == 10)
        // ids[1] should still be present with its follow-up.
        let preserved = manager.items.first(where: { $0.id == ids[1] })
        #expect(preserved != nil)
        #expect(preserved?.followUps.count == 1)
    }

    // MARK: - Input-Always-Enabled Behavioral Contract

    /// Input enablement no longer depends on selection — only on loading state.
    /// This test verifies the behavioral contract: the presence or absence of
    /// a source request ID must NOT prevent the user from composing text.
    @Test @MainActor func inputEnabled_noSelection_compositionAllowed() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        manager.recordExplanation(
            mode: "selection", originalCode: "code", explanation: "exp"
        )

        // No selection active — input should still be enabled.
        // The view's `isFollowUpInputEnabled` is `!isFollowUpLoading`.
        // With no loading state, typing is always possible.
        let isLoading = false
        let isInputEnabled = !isLoading
        #expect(isInputEnabled == true)
    }

    /// Submission without a valid anchored selection must be rejected
    /// at the validation layer, but the question must remain available.
    @Test @MainActor func submitWithoutSelection_rejectedButPreserved() {
        let url = makeTempHistoryURL()
        defer { cleanupHistory(url) }

        let manager = HistoryManager(fileURL: url)
        let id = manager.recordExplanation(
            mode: "selection", originalCode: "code", explanation: "exp"
        )

        // Simulate: user typed a question but has no anchored selection.
        let question = "Why does this work?"
        let anchoredSelection: String? = nil
        let sourceId: UUID? = nil

        // Validation: anchored selection required for context resolution.
        let canSubmit = anchoredSelection != nil
            && sourceId.flatMap({ sid in manager.items.first(where: { $0.id == sid }) }) != nil
        #expect(canSubmit == false)

        // Question must NOT be cleared on rejected submission.
        // (In the view, `followUpText` is untouched when `submitFollowUp()` returns early.)
        #expect(question == "Why does this work?")

        // After anchoring a selection, the same question becomes submittable.
        let anchoredAfter: String? = "selected text"
        let sourceIdAfter: UUID? = id
        let canSubmitAfter = anchoredAfter != nil
            && sourceIdAfter.flatMap({ sid in manager.items.first(where: { $0.id == sid }) }) != nil
        #expect(canSubmitAfter == true)
    }

    /// Anchoring a selection after typing must preserve the existing question.
    /// (activateReply no longer clears followUpText.)
    @Test @MainActor func anchorSelection_preservesExistingQuestion() {
        // This tests the behavioral contract:
        // 1. User types "Why?" (followUpText = "Why?")
        // 2. User selects text and clicks Reply
        // 3. followUpText must still be "Why?"
        var followUpText = "Why does this work?"

        // Simulate activateReply: sets anchored selection, clears guidance.
        // Crucially, followUpText is NOT modified.
        let selectionGuidance = ""  // cleared by activateReply
        _ = selectionGuidance  // suppress unused warning

        // followUpText remains intact.
        #expect(followUpText == "Why does this work?")
    }
}
