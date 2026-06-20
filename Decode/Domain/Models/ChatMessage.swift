import Foundation

/// A single message in a session's conversation history.
///
/// Chat messages are append-only within a session. They track the full
/// conversation between the user and the AI provider, including system
/// messages used for context injection.
///
/// Maps to the `messages` table in the database.
struct ChatMessage: Identifiable, Sendable, Codable, Hashable {

    let id: UUID
    let sessionId: UUID
    let role: MessageRole
    let content: String
    let createdAt: Date
}

/// The role of a participant in a chat conversation.
enum MessageRole: String, Sendable, Codable, CaseIterable {
    case user
    case assistant
    case system
}
