// AIProviderRegistry.swift — Multi-Provider AI Platform
//
// Lightweight registry for AI providers. Avoids switch statements
// and hardcoded provider references outside of initialization.
//
// Providers are registered once at startup by AppDependencies.
// Consumers look up providers by identifier when needed.
//
// Intentionally minimal — no protocol, no generics, no overengineering.

import Foundation

/// A lightweight registry of AI providers indexed by identifier.
///
/// Registered during `AppDependencies.performDeferredStartup()`.
/// Provides a single place to query which providers are available
/// without hardcoding provider types throughout the codebase.
///
/// ## Usage
/// ```swift
/// registry.register(groqProvider, identifier: "groq")
/// if let provider = registry.provider(for: "groq") { ... }
/// ```
@MainActor
final class AIProviderRegistry {

    // MARK: - State

    /// Registered providers, keyed by identifier.
    private var providers: [String: any AIProviderProtocol] = [:]

    /// Availability status per provider, keyed by identifier.
    private var availability: [String: Bool] = [:]

    // MARK: - Registration

    /// Register a provider with the given identifier.
    ///
    /// - Parameters:
    ///   - provider: The provider instance.
    ///   - identifier: Stable string identifier (e.g., "anthropic", "groq").
    ///   - isAvailable: Whether the provider is configured and ready.
    ///     Providers without API keys should be registered as unavailable
    ///     so the registry knows about them but doesn't route to them.
    func register(
        _ provider: any AIProviderProtocol,
        identifier: String,
        isAvailable: Bool = true
    ) {
        providers[identifier] = provider
        availability[identifier] = isAvailable

        #if DEBUG
        print("[AIProviderRegistry] Registered '\(identifier)' (available: \(isAvailable))")
        #endif
    }

    // MARK: - Lookup

    /// Look up a provider by identifier.
    ///
    /// Returns `nil` if the identifier is not registered.
    func provider(for identifier: String) -> (any AIProviderProtocol)? {
        providers[identifier]
    }

    /// Check whether a provider is registered and available.
    func isAvailable(_ identifier: String) -> Bool {
        availability[identifier] ?? false
    }

    /// All registered provider identifiers.
    var registeredIdentifiers: [String] {
        Array(providers.keys).sorted()
    }

    /// The number of registered providers.
    var count: Int {
        providers.count
    }

    /// The number of available (configured) providers.
    var availableCount: Int {
        availability.values.filter { $0 }.count
    }
}
