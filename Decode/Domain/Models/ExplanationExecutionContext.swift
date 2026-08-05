import Foundation

/// Records which capabilities actually participated in generating an explanation.
///
/// Created at the start of an explanation flow. Each subsystem marks its
/// contribution at the point of participation — not before, not after.
/// The HUD renders from this context; no subsystem inspects prompt strings.
///
/// To add a future capability (e.g., Project Intelligence), add a `Bool`
/// property and append its label in ``labels``.
@MainActor
final class ExplanationExecutionContext: Sendable {

    // MARK: - Core (set at creation)

    /// The mode that produced this explanation (e.g., "selection", "screenshot", "session").
    let mode: String

    /// The explanation profile (e.g., "general", "dsa").
    let explanationProfile: String

    // MARK: - Capability contributions (set by each subsystem)

    /// Set `true` by the coordinator when visual context is injected into the prompt.
    var vision: Bool = false

    /// Set `true` by the coordinator when working memory is injected into the prompt.
    var virtualSession: Bool = false

    // MARK: - Init

    init(mode: String, explanationProfile: String) {
        self.mode = mode
        self.explanationProfile = explanationProfile
    }

    // MARK: - Display

    /// Ordered, human-readable labels for every capability that contributed.
    ///
    /// Order: Mode · Profile · Vision · Virtual Session · (future)
    var labels: [String] {
        var result: [String] = []

        // 1. Mode
        switch mode {
        case "selection": result.append("Selection")
        case "screenshot": result.append("Screenshot")
        case "session": result.append("Session")
        default: result.append(mode.capitalized)
        }

        // 2. Explanation profile
        switch explanationProfile {
        case "dsa": result.append("DSA")
        default: result.append("General")
        }

        // 3. Vision
        if vision { result.append("Vision") }

        // 4. Virtual Session
        if virtualSession { result.append("Virtual Session") }

        return result
    }

    /// Formatted display string joining all labels with " · ".
    var displayText: String {
        labels.joined(separator: " · ")
    }
}
