import Foundation

/// The AI provider backend to use for LLM requests.
enum AIProviderType: String, Sendable, Codable, CaseIterable, Identifiable {
    case openAI
    case openRouter
    case custom
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .custom: "Custom Endpoint"
        case .anthropic: "Anthropic"
        }
    }
}

/// A model available from an AI provider.
struct AIModelDefinition: Sendable, Hashable, Identifiable {
    let id: String
    let displayName: String
}

/// Describes an AI provider's endpoint, keychain account, and available models.
struct ProviderDefinition: Sendable {
    let providerType: AIProviderType
    let baseURL: URL
    let apiPath: String
    let keychainAccount: String
    let defaultModels: [AIModelDefinition]
    let defaultModelID: String
    let keyPlaceholder: String
    let isImplemented: Bool

    static let openAI = ProviderDefinition(
        providerType: .openAI,
        baseURL: URL(string: "https://api.openai.com")!,
        apiPath: "/v1/chat/completions",
        keychainAccount: "openai-api-key",
        defaultModels: [
            AIModelDefinition(id: "gpt-4o", displayName: "GPT-4o"),
            AIModelDefinition(id: "gpt-4o-mini", displayName: "GPT-4o Mini"),
        ],
        defaultModelID: "gpt-4o",
        keyPlaceholder: "sk-...",
        isImplemented: true
    )

    static let openRouter = ProviderDefinition(
        providerType: .openRouter,
        baseURL: URL(string: "https://openrouter.ai/api")!,
        apiPath: "/v1/chat/completions",
        keychainAccount: "openrouter-api-key",
        defaultModels: [
            AIModelDefinition(id: "anthropic/claude-sonnet-4-20250514", displayName: "Claude Sonnet 4"),
            AIModelDefinition(id: "openai/gpt-4o", displayName: "GPT-4o"),
            AIModelDefinition(id: "deepseek/deepseek-chat", displayName: "DeepSeek Chat"),
        ],
        defaultModelID: "anthropic/claude-sonnet-4-20250514",
        keyPlaceholder: "sk-or-...",
        isImplemented: true
    )

    static let custom = ProviderDefinition(
        providerType: .custom,
        baseURL: URL(string: "http://localhost:1234")!,
        apiPath: "/v1/chat/completions",
        keychainAccount: "custom-api-key",
        defaultModels: [],
        defaultModelID: "",
        keyPlaceholder: "API key (if required)",
        isImplemented: true
    )

    static let anthropic = ProviderDefinition(
        providerType: .anthropic,
        baseURL: URL(string: "https://api.anthropic.com")!,
        apiPath: "/v1/messages",
        keychainAccount: "anthropic-api-key",
        defaultModels: [
            AIModelDefinition(id: "claude-sonnet-4-20250514", displayName: "Claude Sonnet 4"),
            AIModelDefinition(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5"),
        ],
        defaultModelID: "claude-sonnet-4-20250514",
        keyPlaceholder: "sk-ant-...",
        isImplemented: true
    )

    static func definition(for type: AIProviderType) -> ProviderDefinition {
        switch type {
        case .openAI: .openAI
        case .openRouter: .openRouter
        case .custom: .custom
        case .anthropic: .anthropic
        }
    }
}
