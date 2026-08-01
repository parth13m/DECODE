import Foundation
import Observation

/// Shared mutable state for inspecting Enhanced Explanation results in the debug UI.
///
/// **Temporary debugging aid** — remove once the feature is verified working.
/// Both coordinators write to `shared` after a successful vision extraction.
/// The debug UI in `ContentView` reads from `shared` to display the latest result.
///
/// Uses `@Observable` so SwiftUI automatically re-renders when properties change.
@Observable
@MainActor
final class EnhancedExplanationDebug {

    static let shared = EnhancedExplanationDebug()

    /// The most recent Visual Context produced by the vision extractor.
    var lastVisualContext: VisualContext?

    /// When the last Visual Context was produced or failed.
    var lastTimestamp: Date?

    /// The most recent error from a failed vision request.
    var lastError: String?

    /// Raw vision response text before parsing (for debugging parser correctness).
    var lastRawResponse: String?

    /// Vision request latency in milliseconds.
    var lastLatencyMs: Double?

    private init() {}
}
