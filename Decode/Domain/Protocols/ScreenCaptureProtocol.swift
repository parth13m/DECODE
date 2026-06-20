import Foundation
import CoreGraphics

/// The result of a screen region capture.
struct ScreenCaptureResult: Sendable {
    /// The captured image as a CGImage.
    let image: CGImage

    /// The screen region that was captured (in screen coordinates).
    let capturedRect: CGRect
}

/// Defines the contract for interactive screen region capture.
///
/// Used by Screenshot Mode as a fallback when no text is selected.
/// The concrete implementation presents a transparent fullscreen overlay
/// that allows the user to drag-select a region of the screen.
protocol ScreenCaptureProtocol: Sendable {

    /// Present the screen capture overlay and wait for the user to select a region.
    ///
    /// Returns `nil` if the user cancels the capture (e.g., presses Escape).
    @MainActor
    func captureScreenRegion() async -> ScreenCaptureResult?
}
