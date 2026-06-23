import Foundation

/// The identity understanding of a source file — answers "What am I looking at?"
///
/// Captures the instant recognition an experienced engineer has when opening
/// a file: its role in the system, its architectural layer, and the key
/// patterns it employs. This is the first understanding layer in Decode's
/// progressive comprehension model.
///
/// Identity is derived deterministically from file name, entity structure,
/// and language. It requires no LLM call — it's computed at parse time
/// and injected into the explanation prompt to give the LLM better framing.
struct FileIdentity: Sendable {

    /// The primary role of this file (e.g., "State Manager", "View Model",
    /// "Data Model", "Protocol Definition", "Unit Tests").
    let role: FileRole

    /// The architectural layer this file belongs to.
    let layer: ArchitecturalLayer

    /// Key structural patterns detected (e.g., "Observable state container",
    /// "Dependency injection", "Delegate pattern").
    let patterns: [String]

    /// A one-line human-readable summary combining role, layer, and key signals.
    /// Injected directly into the explanation prompt.
    let summary: String
}

/// The primary role a source file plays in the codebase.
///
/// Roles are broad categories that help frame explanations. They map to
/// how engineers think about files ("this is a manager", "this is a view"),
/// not to language-specific constructs.
enum FileRole: String, Sendable {
    /// Coordinates state and lifecycle (e.g., SessionManager, AuthService).
    case manager
    /// Transforms data for presentation (e.g., ExplanationHUDViewModel).
    case viewModel
    /// Renders UI (e.g., FloatingExplanationHUD, SessionView).
    case view
    /// Defines a data structure or domain object (e.g., Session, CodeEntity).
    case model
    /// Defines a contract/interface (e.g., AIProviderProtocol).
    case protocolDefinition
    /// Extends existing types (file is primarily extensions).
    case extensionFile
    /// Contains test cases.
    case test
    /// Orchestrates multi-step workflows (e.g., SelectionModeCoordinator).
    case coordinator
    /// Provides infrastructure capabilities (e.g., DatabaseService, KeychainService).
    case service
    /// Parses or transforms data (e.g., SwiftSyntaxParser, ExplanationTagParser).
    case parser
    /// Defines constants, configuration, or static data.
    case configuration
    /// App entry point or setup (e.g., DecodeApp, AppDependencies).
    case appEntry
    /// Could not determine a clear role.
    case unknown

    /// Human-readable label for prompt injection.
    var label: String {
        switch self {
        case .manager: return "State Manager"
        case .viewModel: return "View Model"
        case .view: return "View"
        case .model: return "Data Model"
        case .protocolDefinition: return "Protocol Definition"
        case .extensionFile: return "Extension"
        case .test: return "Unit Tests"
        case .coordinator: return "Coordinator"
        case .service: return "Service"
        case .parser: return "Parser / Transformer"
        case .configuration: return "Configuration"
        case .appEntry: return "App Entry Point"
        case .unknown: return "Source File"
        }
    }
}

/// The architectural layer a file belongs to.
///
/// Maps to Decode's layered architecture (Presentation → Application →
/// Domain → Infrastructure) but also covers cross-cutting concerns
/// and languages/projects that don't use this specific layering.
enum ArchitecturalLayer: String, Sendable {
    /// UI rendering, views, overlays, HUD.
    case presentation
    /// Coordinators, managers, business logic orchestration.
    case application
    /// Models, protocols, pure domain types.
    case domain
    /// External system adapters: database, network, file system, parsers.
    case infrastructure
    /// Tests.
    case testing
    /// Could not determine layer.
    case unknown

    /// Human-readable label for prompt injection.
    var label: String {
        switch self {
        case .presentation: return "Presentation layer"
        case .application: return "Application layer"
        case .domain: return "Domain layer"
        case .infrastructure: return "Infrastructure layer"
        case .testing: return "Test suite"
        case .unknown: return ""
        }
    }
}
