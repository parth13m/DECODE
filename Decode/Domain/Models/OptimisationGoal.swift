import Foundation

/// The optimisation goal selected by the user when clicking "Optimise".
///
/// Provider-independent — prompt builders translate this into provider-specific
/// instructions. The enum carries only identity and display metadata.
enum OptimisationGoal: String, CaseIterable, Sendable {
    case balanced
    case performance
    case memoryEfficient

    var displayName: String {
        switch self {
        case .balanced: "Balanced"
        case .performance: "Performance"
        case .memoryEfficient: "Memory Efficient"
        }
    }

    var icon: String {
        switch self {
        case .balanced: "⚖️"
        case .performance: "⚡"
        case .memoryEfficient: "💾"
        }
    }

    var description: String {
        switch self {
        case .balanced: "Balances readability, maintainability and performance."
        case .performance: "Focus on execution speed."
        case .memoryEfficient: "Focus on reducing memory usage."
        }
    }
}
