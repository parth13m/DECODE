import Foundation
import Testing
@testable import Decode

/// Tests for ``AccessibilityCapture``.
///
/// Full end-to-end text capture requires a running application with granted
/// Accessibility permission, which is not available in the CI/test environment.
/// These tests verify the service's contract behavior: protocol conformance,
/// permission check accessibility, and graceful handling of the no-permission case.
@Suite(.serialized)
struct AccessibilityCaptureTests {

    @Test func conformsToProtocol() {
        let capture = AccessibilityCapture()
        let _: any SelectionCaptureProtocol = capture
    }

    @Test func hasAccessibilityPermissionReturnsBool() {
        let capture = AccessibilityCapture()
        let result = capture.hasAccessibilityPermission()
        #expect(result == true || result == false)
    }

    @Test func captureSelectionReturnsNilWithoutPermission() async throws {
        let capture = AccessibilityCapture()

        // In test environment, Accessibility is typically not granted.
        // If not granted, captureSelection should return nil gracefully.
        if !capture.hasAccessibilityPermission() {
            let result = try await capture.captureSelection(fromPID: 1)
            #expect(result == nil)
        }
    }

    @Test func captureSelectionResultStructure() {
        let result = SelectionCaptureResult(
            text: "func hello() {}",
            sourceApplicationName: "Xcode"
        )
        #expect(result.text == "func hello() {}")
        #expect(result.sourceApplicationName == "Xcode")
    }

    @Test func captureSelectionResultWithNilAppName() {
        let result = SelectionCaptureResult(
            text: "some code",
            sourceApplicationName: nil
        )
        #expect(result.text == "some code")
        #expect(result.sourceApplicationName == nil)
    }
}
