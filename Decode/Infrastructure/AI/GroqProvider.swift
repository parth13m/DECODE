// GroqProvider.swift — Multi-Provider AI Architecture
//
// Thin wrapper around OpenAICompatibleProvider configured for Groq's
// inference API. Used by the Knowledge Generation Runtime for background
// knowledge production (File Understanding, future Module/Architecture
// Understanding).
//
// No business logic references Groq directly — all routing is through
// KnowledgeCapabilityResolver. This file is pure infrastructure.
//
// Configuration is injected via ProviderConfig — the provider never
// reads environment variables directly.

import Foundation

/// AI provider for Groq's OpenAI-compatible inference API.
///
/// Used exclusively by the KGR for background knowledge generation.
/// Premium reasoning (Explain, Follow-up, Improve) continues through
/// the Decode Gateway → Claude path.
///
/// ## Configuration
/// Receives a `ProviderConfig` via dependency injection. The config
/// is created by `AIConfiguration.fromEnvironment()` at startup.
///
/// ## Availability
/// Check ``isAvailable`` before attempting requests. Returns `false`
/// when no API key is configured — the caller should fall back to
/// the primary provider.
final class GroqProvider: AIProviderProtocol, Sendable {

    /// The underlying OpenAI-compatible provider instance (text model).
    private let provider: OpenAICompatibleProvider

    /// A separate provider configured with the vision model.
    /// Used for Enhanced Explanation image analysis.
    private let visionProvider: OpenAICompatibleProvider

    /// Whether a Groq API key is available.
    ///
    /// When `false`, the KGR capability resolver should fall back
    /// to the primary provider (Claude via gateway).
    let isAvailable: Bool

    // MARK: - Init

    /// Creates a GroqProvider from a `ProviderConfig`.
    ///
    /// - Parameters:
    ///   - config: Provider configuration containing API key, model, and base URL.
    ///   - visionModel: Model identifier for vision requests.
    ///   - client: Network client for HTTP communication.
    init(
        config: ProviderConfig,
        visionModel: String = AIConfiguration.defaultGroqVisionModel,
        client: AINetworkClient = AINetworkClient()
    ) {
        self.isAvailable = config.isAvailable

        let apiKey = config.apiKey
        self.provider = OpenAICompatibleProvider(
            apiKey: { apiKey },
            modelID: config.model,
            client: client,
            baseURL: config.baseURL
        )
        self.visionProvider = OpenAICompatibleProvider(
            apiKey: { apiKey },
            modelID: visionModel,
            client: client,
            baseURL: config.baseURL
        )
    }

    /// Creates a GroqProvider from explicit parameters.
    ///
    /// Convenience initializer for tests and cases where a full
    /// `ProviderConfig` is not needed.
    init(
        apiKey: @escaping @Sendable () -> String?,
        model: String = AIConfiguration.defaultGroqModel,
        visionModel: String = AIConfiguration.defaultGroqVisionModel,
        client: AINetworkClient = AINetworkClient()
    ) {
        let key = apiKey()
        self.isAvailable = key != nil && !(key?.isEmpty ?? true)

        self.provider = OpenAICompatibleProvider(
            apiKey: apiKey,
            modelID: model,
            client: client,
            baseURL: AIConfiguration.groqBaseURL
        )
        self.visionProvider = OpenAICompatibleProvider(
            apiKey: apiKey,
            modelID: visionModel,
            client: client,
            baseURL: AIConfiguration.groqBaseURL
        )
    }

    // MARK: - AIProviderProtocol

    func generateCompletion(
        userContent: String,
        systemPrompt: String,
        mode: String?
    ) async throws -> String {
        try await provider.generateCompletion(
            userContent: userContent,
            systemPrompt: systemPrompt,
            mode: mode
        )
    }

    func streamChat(
        messages: [AIMessage],
        systemPrompt: String,
        mode: String?,
        contextTier: String?,
        explanationProfile: String?,
        language: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        try await provider.streamChat(
            messages: messages,
            systemPrompt: systemPrompt,
            mode: mode,
            contextTier: contextTier,
            explanationProfile: explanationProfile,
            language: language
        )
    }

    func generateVisionCompletion(
        imageData: Data,
        prompt: String,
        mode: String?
    ) async throws -> String {
        try await visionProvider.generateVisionCompletion(
            imageData: imageData,
            prompt: prompt,
            mode: mode
        )
    }

    func validateConnection() async throws {
        try await provider.validateConnection()
    }
}
