// AIConfiguration.swift — Multi-Provider AI Platform
//
// Single source of truth for all AI provider configuration.
//
// The rest of the application must NEVER read ProcessInfo.environment
// for AI-related variables directly. All configuration flows through
// this type.
//
// ## Naming Convention
// Each provider has two environment variables:
//   <PROVIDER>_API_KEY  — required for the provider to be available
//   <PROVIDER>_MODEL    — optional, falls back to a built-in default
//
// Adding a new provider: add a ProviderConfig entry and a
// static factory/property on AIConfiguration.

import Foundation

// MARK: - Provider Configuration

/// Configuration for a single AI provider.
///
/// Immutable after construction. Providers receive this via dependency
/// injection — they never read environment variables themselves.
struct ProviderConfig: Sendable {

    /// Human-readable identifier (e.g., "anthropic", "groq").
    let identifier: String

    /// API key. `nil` or empty means the provider is not available.
    let apiKey: String?

    /// Model identifier sent in requests.
    let model: String

    /// Base URL for API requests.
    let baseURL: URL

    /// Whether this provider has a valid API key configured.
    var isAvailable: Bool {
        guard let key = apiKey else { return false }
        return !key.isEmpty
    }
}

// MARK: - AI Configuration

/// Loads and validates all AI provider configuration from environment variables.
///
/// Created once during `AppDependencies.performDeferredStartup()` and passed
/// to provider constructors. No other code should read `ProcessInfo.environment`
/// for AI settings.
///
/// ## Provider Configuration Standard
/// ```
/// ANTHROPIC_API_KEY   — Anthropic API key (gateway provider)
/// ANTHROPIC_MODEL     — Anthropic model (default: claude-haiku-4-5-20251001)
/// GROQ_API_KEY        — Groq API key (direct provider)
/// GROQ_MODEL          — Groq model (default: llama-3.3-70b-versatile)
/// ```
struct AIConfiguration: Sendable {

    /// Anthropic provider configuration (premium reasoning).
    let anthropic: ProviderConfig

    /// Groq provider configuration (background knowledge production).
    let groq: ProviderConfig

    /// Groq vision model identifier for Enhanced Explanation.
    let groqVisionModel: String

    /// Validation issues found during loading. Empty = clean.
    let validationIssues: [String]

    // MARK: - Default Models

    /// Default Anthropic model for premium reasoning.
    static let defaultAnthropicModel = "claude-haiku-4-5-20251001"

    /// Default Groq model for knowledge generation.
    static let defaultGroqModel = "llama-3.3-70b-versatile"

    /// Default Groq vision model for Enhanced Explanation.
    static let defaultGroqVisionModel = "llama-3.2-90b-vision-preview"

    // MARK: - Base URLs

    /// Groq API base URL (OpenAI-compatible endpoint).
    static let groqBaseURL = URL(string: "https://api.groq.com/openai")!

    /// Anthropic API base URL (used by direct provider, not gateway).
    static let anthropicBaseURL = URL(string: "https://api.anthropic.com")!

    // MARK: - Loading from Environment

    /// Load configuration from process environment variables.
    ///
    /// This is the canonical way to create an `AIConfiguration`.
    /// Called once at startup.
    static func fromEnvironment() -> AIConfiguration {
        let env = ProcessInfo.processInfo.environment
        var issues: [String] = []

        // Anthropic configuration.
        let anthropicKey = env["ANTHROPIC_API_KEY"]
        let anthropicModel = env["ANTHROPIC_MODEL"] ?? defaultAnthropicModel

        // Groq configuration.
        let groqKey = env["GROQ_API_KEY"]
        let groqModel = env["GROQ_MODEL"] ?? defaultGroqModel
        let groqVisionModel = env["GROQ_VISION_MODEL"] ?? defaultGroqVisionModel

        // Validation.
        if anthropicKey == nil || anthropicKey?.isEmpty == true {
            issues.append("ANTHROPIC_API_KEY not set — Anthropic direct provider unavailable (gateway still works via Decode access token)")
        }
        if groqKey == nil || groqKey?.isEmpty == true {
            issues.append("GROQ_API_KEY not set — Groq provider unavailable, knowledge generation will use primary provider")
        }

        let anthropicConfig = ProviderConfig(
            identifier: "anthropic",
            apiKey: anthropicKey,
            model: anthropicModel,
            baseURL: anthropicBaseURL
        )

        let groqConfig = ProviderConfig(
            identifier: "groq",
            apiKey: groqKey,
            model: groqModel,
            baseURL: groqBaseURL
        )

        return AIConfiguration(
            anthropic: anthropicConfig,
            groq: groqConfig,
            groqVisionModel: groqVisionModel,
            validationIssues: issues
        )
    }

    /// Create a test configuration with explicit values.
    static func test(
        anthropicKey: String? = nil,
        anthropicModel: String = defaultAnthropicModel,
        groqKey: String? = nil,
        groqModel: String = defaultGroqModel,
        groqVisionModel: String = defaultGroqVisionModel
    ) -> AIConfiguration {
        AIConfiguration(
            anthropic: ProviderConfig(
                identifier: "anthropic",
                apiKey: anthropicKey,
                model: anthropicModel,
                baseURL: anthropicBaseURL
            ),
            groq: ProviderConfig(
                identifier: "groq",
                apiKey: groqKey,
                model: groqModel,
                baseURL: groqBaseURL
            ),
            groqVisionModel: groqVisionModel,
            validationIssues: []
        )
    }

    // MARK: - Diagnostics

    /// Log configuration status at startup.
    func logStatus() {
        #if DEBUG
        print("[AIConfiguration] Anthropic: \(anthropic.isAvailable ? "available" : "unavailable") (model: \(anthropic.model))")
        print("[AIConfiguration] Groq: \(groq.isAvailable ? "available" : "unavailable") (model: \(groq.model))")
        for issue in validationIssues {
            print("[AIConfiguration] ⚠ \(issue)")
        }
        #endif
    }
}
