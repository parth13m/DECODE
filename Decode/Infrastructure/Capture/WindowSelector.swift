import Foundation
@preconcurrency import ScreenCaptureKit

/// Selects the best content window from a list of SCWindows belonging to a process.
///
/// Uses a weighted scoring system to rank candidate windows. The strategy
/// is derived from runtime analysis of how macOS applications (Xcode, VS Code,
/// Terminal, etc.) expose windows to ScreenCaptureKit:
///
/// - Main content/document windows have non-empty titles and layer 0.
/// - Toolbars, title bar chrome, and auxiliary windows have empty/nil titles.
/// - Menu bar overlays use elevated window layers (e.g. 26).
/// - Floating panels use positive window layers.
///
/// Scoring weights are tuned so that a single titled, layer-0, active window
/// is selected deterministically — no heuristic tiebreaking needed in the
/// common case. Area-based scoring acts as a fallback for edge cases.
enum WindowSelector {

    // MARK: - Scoring Weights

    /// Non-empty title is the strongest signal for a content window.
    private static let titleBonus: Double = 1000

    /// Normal window layer (0) is expected for all content windows.
    private static let normalLayerBonus: Double = 500

    /// Active window bonus (Stage Manager aware).
    private static let activeBonus: Double = 100

    /// On-screen bonus (defensive — should always be true with our query).
    private static let onScreenBonus: Double = 50

    /// Area is normalized to [0, 200] so it only breaks ties, never overrides
    /// title or layer signals.
    private static let maxAreaScore: Double = 200

    // MARK: - Selection

    /// Select the best content window for a given PID from a list of SCWindows.
    ///
    /// - Parameters:
    ///   - windows: All windows returned by `SCShareableContent.windows`.
    ///   - pid: The process ID of the target application.
    /// - Returns: The highest-scoring window, or `nil` if no window matches the PID.
    static func selectWindow(from windows: [SCWindow], forPID pid: pid_t) -> SCWindow? {
        let candidates = windows.filter {
            $0.owningApplication?.processID == pid
        }

        guard !candidates.isEmpty else { return nil }

        // Find the maximum area among candidates for normalization.
        let maxArea = candidates.map { Double($0.frame.width * $0.frame.height) }.max() ?? 1.0

        var bestWindow: SCWindow?
        var bestScore: Double = -.infinity

        #if DEBUG
        var scoredWindows: [(window: SCWindow, score: Double)] = []
        #endif

        for window in candidates {
            let score = self.score(window: window, maxArea: maxArea)

            #if DEBUG
            scoredWindows.append((window, score))
            #endif

            if score > bestScore {
                bestScore = score
                bestWindow = window
            }
        }

        #if DEBUG
        let appName = candidates.first?.owningApplication?.applicationName ?? "unknown"
        print("[WindowSelector] PID \(pid) (\(appName)): \(candidates.count) candidates")
        for (window, score) in scoredWindows {
            let marker = window.windowID == bestWindow?.windowID ? "▶" : " "
            let title = window.title?.isEmpty == false ? window.title! : "<no title>"
            print("[WindowSelector] \(marker) id=\(window.windowID) score=\(String(format: "%.0f", score)) title=\"\(title)\" \(Int(window.frame.width))×\(Int(window.frame.height)) layer=\(window.windowLayer)")
        }
        #endif

        return bestWindow
    }

    // MARK: - Scoring

    /// Compute a numeric score for a single window.
    private static func score(window: SCWindow, maxArea: Double) -> Double {
        var score: Double = 0

        // Title: non-nil AND non-empty.
        if let title = window.title, !title.isEmpty {
            score += titleBonus
        }

        // Normal window layer (0).
        if window.windowLayer == 0 {
            score += normalLayerBonus
        }

        // Active (Stage Manager aware, available since macOS 13.1).
        if window.isActive {
            score += activeBonus
        }

        // On screen.
        if window.isOnScreen {
            score += onScreenBonus
        }

        // Normalized area: larger windows score higher, but capped at maxAreaScore.
        let area = Double(window.frame.width * window.frame.height)
        if maxArea > 0 {
            score += (area / maxArea) * maxAreaScore
        }

        return score
    }
}
