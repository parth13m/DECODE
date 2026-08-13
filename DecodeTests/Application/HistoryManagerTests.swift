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
            explanationProfile: nil, followUps: []
        )
        let r2 = HistoryRequest(
            id: UUID(), createdAt: stableDate(1), mode: "session",
            originalCode: "c", explanation: "d",
            sourceAppName: nil, fileName: nil, language: nil,
            explanationProfile: nil, followUps: []
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
            followUps: [followUp]
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
}
