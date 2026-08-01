import Foundation

/// Shared mutable state for inspecting Enhanced Explanation results in the debug UI.
///
/// **Temporary debugging aid** — remove once the feature is verified working.
/// Both coordinators write to `shared` after a successful vision extraction.
/// The debug UI in `ContentView` reads from `shared` to display the latest result.
@MainActor
final class EnhancedExplanationDebug: Observable {

    static let shared = EnhancedExplanationDebug()

    /// The most recent Visual Context produced by the vision extractor.
    var lastVisualContext: VisualContext?

    /// When the last Visual Context was produced.
    var lastTimestamp: Date?

    private init() {}
}
