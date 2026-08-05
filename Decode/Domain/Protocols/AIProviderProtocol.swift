import Foundation

/// A lightweight message for AI provider communication.
///
/// Unlike `ChatMessage`, carries no session or database context.
/// Used at the AI protocol boundary so providers don't depend on
/// session-specific types. Selection/Screenshot modes use this directly;
/// Session Mode converts `ChatMessage` -> `AIMessage` before calling providers.
struct AIMessage: Sendable, Codable, Hashable {
    let role: MessageRole
    let content: String
}

/// Defines the contract for all AI/LLM communication.
///
/// The Domain layer defines this protocol; the Infrastructure layer provides
/// concrete implementations for OpenAI, Anthropic, or other providers.
/// All provider-specific details (API keys, endpoints, model names) are
/// encapsulated in the concrete implementation.
protocol AIProviderProtocol: Sendable {

    /// Generate a non-streaming completion given user content and a system prompt.
    ///
    /// - Parameter mode: The request mode for server-side tracking
    ///   (`"selection"`, `"screenshot"`, `"session"`). Providers that don't
    ///   support mode tracking may ignore this parameter.
    func generateCompletion(
        userContent: String,
        systemPrompt: String,
        mode: String?
    ) async throws -> String

    /// Stream a chat response given a conversation history.
    ///
    /// - Parameter mode: The request mode for server-side tracking.
    /// - Parameter contextTier: The context tier for analytics (e.g., `"pipeline"`).
    ///   `nil` for non-session modes.
    /// - Parameter explanationProfile: The explanation profile for analytics
    ///   (`"general"`, `"dsa"`). `nil` defaults to general.
    func streamChat(
        messages: [AIMessage],
        systemPrompt: String,
        mode: String?,
        contextTier: String?,
        explanationProfile: String?,
        language: String?
    ) async throws -> AsyncThrowingStream<String, Error>

    /// Validate that the provider is correctly configured and reachable.
    func validateConnection() async throws

    /// Generate a non-streaming completion from an image and a text prompt.
    ///
    /// Used by Enhanced Explanation (Visual Context) extraction. Non-streaming
    /// because the output is short structured evidence (~100 tokens), not a
    /// user-facing narrative. `imageData` is JPEG bytes — platform-portable,
    /// no CoreGraphics dependency in the Domain layer.
    ///
    /// - Parameter imageData: JPEG-encoded image bytes.
    /// - Parameter prompt: The extraction prompt.
    /// - Parameter mode: The request mode for server-side tracking.
    func generateVisionCompletion(
        imageData: Data,
        prompt: String,
        mode: String?
    ) async throws -> String
}

// Default overloads so callers that don't need mode tracking can omit it.
extension AIProviderProtocol {

    // Default: providers that don't support vision fail explicitly.
    func generateVisionCompletion(
        imageData: Data, prompt: String, mode: String?
    ) async throws -> String {
        throw AIProviderError.unsupportedCapability("Vision")
    }

    func generateCompletion(
        userContent: String,
        systemPrompt: String
    ) async throws -> String {
        try await generateCompletion(userContent: userContent, systemPrompt: systemPrompt, mode: nil)
    }

    func streamChat(
        messages: [AIMessage],
        systemPrompt: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        try await streamChat(messages: messages, systemPrompt: systemPrompt, mode: nil, contextTier: nil, explanationProfile: nil, language: nil)
    }

    func streamChat(
        messages: [AIMessage],
        systemPrompt: String,
        mode: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        try await streamChat(messages: messages, systemPrompt: systemPrompt, mode: mode, contextTier: nil, explanationProfile: nil, language: nil)
    }

    func streamChat(
        messages: [AIMessage],
        systemPrompt: String,
        mode: String?,
        contextTier: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        try await streamChat(messages: messages, systemPrompt: systemPrompt, mode: mode, contextTier: contextTier, explanationProfile: nil, language: nil)
    }

    func streamChat(
        messages: [AIMessage],
        systemPrompt: String,
        mode: String?,
        contextTier: String?,
        explanationProfile: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        try await streamChat(messages: messages, systemPrompt: systemPrompt, mode: mode, contextTier: contextTier, explanationProfile: explanationProfile, language: nil)
    }
}
