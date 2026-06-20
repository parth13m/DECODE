import Foundation

/// The result of capturing selected text from an application.
struct SelectionCaptureResult: Sendable {
    /// The captured text content.
    let text: String

    /// The name of the application the text was captured from, if available.
    let sourceApplicationName: String?
}

/// Defines the contract for capturing highlighted text from any macOS application.
///
/// Used by Selection Mode. The concrete implementation uses Accessibility APIs
/// (AXUIElement) to read the selected text from a target application's
/// focused text field.
///
/// Requires the user to grant Accessibility permission in System Settings.
protocol SelectionCaptureProtocol: Sendable {

    /// Capture the currently selected text from the specified application process.
    ///
    /// - Parameter pid: The process identifier of the target application.
    ///   Captured synchronously at hotkey time to avoid frontmost-app race conditions.
    /// - Returns: The selected text and source app name, or `nil` if no text is selected
    ///   or the app doesn't expose its selection via Accessibility APIs.
    func captureSelection(fromPID pid: pid_t) async throws -> SelectionCaptureResult?

    /// Check whether Accessibility permission has been granted.
    func hasAccessibilityPermission() -> Bool

    /// Prompt the user to grant Accessibility permission.
    func requestAccessibilityPermission()
}
