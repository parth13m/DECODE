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

/// Configuration for cropping captured screenshots before vision processing.
///
/// Removes a configurable percentage from each edge to discard window chrome
/// (title bars, toolbars, sidebars, status bars) and reduce the number of
/// image tokens sent to the vision model. Works universally across all
/// application types — IDEs, browsers, PDFs, documentation.
struct VisualContextCaptureConfiguration: Sendable {

    /// Fraction of total width to remove from each horizontal edge (left and right).
    /// `0.10` means 10% removed from left + 10% removed from right = 20% horizontal reduction.
    let horizontalPaddingPercent: Double

    /// Fraction of total height to remove from each vertical edge (top and bottom).
    /// `0.10` means 10% removed from top + 10% removed from bottom = 20% vertical reduction.
    let verticalPaddingPercent: Double

    /// Default configuration: 10% from each edge.
    static let `default` = VisualContextCaptureConfiguration(
        horizontalPaddingPercent: 0.10,
        verticalPaddingPercent: 0.10
    )

    /// No cropping — use the full captured image.
    static let none = VisualContextCaptureConfiguration(
        horizontalPaddingPercent: 0,
        verticalPaddingPercent: 0
    )
}
