import Foundation
import Testing
@testable import Decode

/// Tests for the ChatMessage domain model and MessageRole enum.
struct ChatMessageTests {

    @Test func messageRoleCodableRoundTrip() throws {
        for role in MessageRole.allCases {
            let data = try JSONEncoder().encode(role)
            let decoded = try JSONDecoder().decode(MessageRole.self, from: data)
            #expect(decoded == role)
        }
    }
}
