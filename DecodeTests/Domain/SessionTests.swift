import Foundation
import Testing
@testable import Decode

/// Tests for the Session domain model.
struct SessionTests {

    @Test func sessionIsIdentifiable() {
        let session = Session(
            id: .init(),
            createdAt: .now,
            updatedAt: .now,
            bookmarkData: Data(),
            filePath: "/tmp/test.swift",
            fileName: "test.swift",
            fileSize: 1024,
            fileModifiedAt: .now,
            fileHash: "abc123",
            summaryText: "",
            isCorrupted: false
        )
        #expect(session.id != UUID())
    }
}
