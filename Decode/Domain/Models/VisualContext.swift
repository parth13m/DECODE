import Foundation

/// Compact contextual evidence extracted from a screenshot of the user's
/// working area. Produced by the vision extraction stage, consumed by the
/// explanation prompt assembly.
///
/// The vision model produces the **final artifact** directly. Decode performs
/// only lightweight validation (strip `<think>` blocks, trim whitespace,
/// enforce character limit). No semantic parsing or transformation.
struct VisualContext: Sendable, Codable, Equatable {

    /// The validated vision model output, ready for injection into Claude's prompt.
    /// Plain text, one observation per line.
    let content: String

    /// Whether the extraction produced any meaningful content.
    var isEmpty: Bool { content.isEmpty }

    /// The content, ready for injection. Identity function — the vision model
    /// produces the final text directly.
    func formatted() -> String { content }
}
