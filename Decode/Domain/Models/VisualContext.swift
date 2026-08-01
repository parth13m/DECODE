import Foundation

/// A single item of visual evidence extracted from a screenshot.
///
/// Each item is a typed observation: a category (`type`) and a concise
/// factual value (`content`). The type is an open string — not an enum —
/// so new observation categories emerge from prompt evolution without
/// requiring schema changes.
///
/// Well-known types: "file", "lang", "editor", "contains", "imports",
/// "warning", "error", "near", "visible".
struct VisualEvidence: Sendable, Codable, Equatable {

    /// The observation category (e.g., "file", "lang", "contains").
    let type: String

    /// The factual content of the observation.
    /// Must be directly observable from the image. Never inferred.
    let content: String
}

/// Compact contextual evidence extracted from a screenshot of the user's
/// working area. Produced by the vision extraction stage, consumed by the
/// explanation prompt assembly.
///
/// Contains an ordered list of typed evidence items. The total output is
/// ~80-120 tokens — aggressively compressed for maximum information density.
struct VisualContext: Sendable, Codable, Equatable {

    /// Ordered evidence items, highest-priority first.
    let items: [VisualEvidence]

    /// Whether the extraction produced any meaningful content.
    var isEmpty: Bool { items.isEmpty }

    /// Format evidence for injection into the explanation user message.
    /// Produces a compact "type: content" block, one line per item.
    func formatted() -> String {
        items.map { "\($0.type): \($0.content)" }.joined(separator: "\n")
    }
}
