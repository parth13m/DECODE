import Foundation
import SwiftUI

/// ViewModel for the Settings screen.
///
/// Manages API key storage/retrieval via Keychain, provider selection,
/// model selection, and connection testing. Supports multiple providers
/// with per-provider keychain accounts and model lists.
@Observable
@MainActor
final class SettingsViewModel {

    // MARK: - Published State

    var apiKeyInput: String = ""
    var selectedProvider: AIProviderType = .openAI
    var selectedModelID: String = "gpt-4o"
    var customBaseURL: String = ""

    var connectionStatus: ConnectionStatus = .untested
    var isTesting: Bool = false
    var hasStoredKey: Bool = false
    var statusMessage: String = ""

    // MARK: - Computed

    var currentDefinition: ProviderDefinition {
        ProviderDefinition.definition(for: selectedProvider)
    }

    var availableModels: [AIModelDefinition] {
        currentDefinition.defaultModels
    }

    // MARK: - Dependencies

    private let keychain: KeychainService
    private let providerFactory: @Sendable (AIProviderType, String, String, URL, String) -> any AIProviderProtocol

    // MARK: - Constants

    private static let providerTypeKey = "selectedProviderType"
    private static let modelIDKey = "selectedModelID"
    private static let customBaseURLKey = "customBaseURL"

    init(
        keychain: KeychainService = KeychainService(),
        providerFactory: @escaping @Sendable (AIProviderType, String, String, URL, String) -> any AIProviderProtocol = { providerType, apiKey, modelID, baseURL, apiPath in
            switch providerType {
            case .anthropic:
                return AnthropicProvider(
                    apiKey: { apiKey },
                    modelID: modelID
                )
            case .openAI, .openRouter, .custom:
                return OpenAICompatibleProvider(
                    apiKey: { apiKey },
                    modelID: modelID,
                    baseURL: baseURL,
                    apiPath: apiPath
                )
            }
        }
    ) {
        self.keychain = keychain
        self.providerFactory = providerFactory
        loadSavedState()
    }

    // MARK: - Actions

    func saveAPIKey() {
        guard !apiKeyInput.isEmpty else { return }
        do {
            try keychain.store(apiKeyInput, forAccount: currentDefinition.keychainAccount)
            hasStoredKey = true
            statusMessage = "API key saved."
            connectionStatus = .untested
            // Persist all settings.
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: Self.providerTypeKey)
            UserDefaults.standard.set(selectedModelID, forKey: Self.modelIDKey)
            if selectedProvider == .custom {
                UserDefaults.standard.set(customBaseURL, forKey: Self.customBaseURLKey)
            }
        } catch {
            statusMessage = "Failed to save: \(error.localizedDescription)"
        }
    }

    func deleteAPIKey() {
        do {
            try keychain.delete(forAccount: currentDefinition.keychainAccount)
            apiKeyInput = ""
            hasStoredKey = false
            connectionStatus = .untested
            statusMessage = "API key removed."
        } catch {
            statusMessage = "Failed to delete: \(error.localizedDescription)"
        }
    }

    func testConnection() {
        guard hasStoredKey || !apiKeyInput.isEmpty else {
            statusMessage = "Enter an API key first."
            return
        }

        // Save only if the user typed a new (unmasked) key.
        if !apiKeyInput.isEmpty && !hasStoredKey {
            saveAPIKey()
        }

        isTesting = true
        connectionStatus = .testing
        statusMessage = "Testing connection..."

        let definition = currentDefinition
        let modelID = selectedModelID
        let baseURL = resolvedBaseURL

        Task {
            do {
                let key = try keychain.retrieve(forAccount: definition.keychainAccount) ?? ""
                let provider = providerFactory(definition.providerType, key, modelID, baseURL, definition.apiPath)
                try await provider.validateConnection()
                self.connectionStatus = .connected
                self.statusMessage = "Connected to \(definition.providerType.displayName)."
            } catch let error as AIProviderError {
                self.connectionStatus = .failed
                self.statusMessage = error.errorDescription ?? "Connection failed."
            } catch {
                self.connectionStatus = .failed
                self.statusMessage = "Connection failed: \(error.localizedDescription)"
            }
            self.isTesting = false
        }
    }

    /// Called when the user switches provider in the picker.
    /// Reloads keychain state and resets model selection for the new provider.
    func onProviderChanged() {
        let definition = currentDefinition
        // Persist provider selection.
        UserDefaults.standard.set(selectedProvider.rawValue, forKey: Self.providerTypeKey)
        // Check if this provider has a stored key.
        if let key = try? keychain.retrieve(forAccount: definition.keychainAccount), !key.isEmpty {
            hasStoredKey = true
            apiKeyInput = maskKey(key)
        } else {
            hasStoredKey = false
            apiKeyInput = ""
        }
        // Reset model to this provider's default.
        selectedModelID = definition.defaultModelID
        UserDefaults.standard.set(selectedModelID, forKey: Self.modelIDKey)
        connectionStatus = .untested
        statusMessage = ""
    }

    /// Persist the current model selection to UserDefaults.
    func persistModelSelection() {
        UserDefaults.standard.set(selectedModelID, forKey: Self.modelIDKey)
    }

    /// Persist the custom base URL to UserDefaults.
    func persistCustomBaseURL() {
        UserDefaults.standard.set(customBaseURL, forKey: Self.customBaseURLKey)
    }

    // MARK: - Private

    private var resolvedBaseURL: URL {
        if selectedProvider == .custom,
           !customBaseURL.isEmpty,
           let url = URL(string: customBaseURL)
        {
            return url
        }
        return currentDefinition.baseURL
    }

    private func loadSavedState() {
        // Load provider type.
        if let raw = UserDefaults.standard.string(forKey: Self.providerTypeKey),
           let provider = AIProviderType(rawValue: raw)
        {
            selectedProvider = provider
        }

        let definition = currentDefinition

        // Check stored key for current provider.
        if let key = try? keychain.retrieve(forAccount: definition.keychainAccount), !key.isEmpty {
            hasStoredKey = true
            apiKeyInput = maskKey(key)
        }

        // Load model ID with migration fallback from legacy "selectedModel" key.
        if let modelID = UserDefaults.standard.string(forKey: Self.modelIDKey) {
            selectedModelID = modelID
        } else if let legacyModel = UserDefaults.standard.string(forKey: "selectedModel") {
            selectedModelID = legacyModel
        } else {
            selectedModelID = definition.defaultModelID
        }

        // Load custom endpoint settings.
        customBaseURL = UserDefaults.standard.string(forKey: Self.customBaseURLKey) ?? ""
    }

    private func maskKey(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "*", count: key.count) }
        let prefix = String(key.prefix(4))
        let suffix = String(key.suffix(4))
        return "\(prefix)...\(suffix)"
    }
}

/// The state of the connection test.
enum ConnectionStatus: Sendable {
    case untested
    case testing
    case connected
    case failed
}
