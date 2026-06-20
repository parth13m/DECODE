import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// Concrete implementation of ``ScreenCaptureProtocol``.
///
/// Presents a drag-to-select overlay on the active screen, captures the full
/// display via ScreenCaptureKit, then crops to the selected region.
///
/// Requires **Screen Recording** permission (TCC `kTCCServiceScreenCapture`).
@MainActor
final class ScreenCaptureServiceImpl: ScreenCaptureProtocol {

    private let overlay = ScreenSelectionOverlay()

    @MainActor
    func captureScreenRegion() async -> ScreenCaptureResult? {
        // 1. Show the selection overlay and wait for the user to select a region.
        guard let selection = await overlay.selectRegion() else {
            #if DEBUG
            print("[DEBUG ScreenCapture] selection cancelled")
            #endif
            return nil
        }

        let screenInfo = selection.screenInfo
        let selectedRect = selection.rectInScreenCoordinates

        #if DEBUG
        print("[DEBUG ScreenCapture] user selected \(Int(selectedRect.width))x\(Int(selectedRect.height)) at (\(Int(selectedRect.origin.x)), \(Int(selectedRect.origin.y)))")
        #endif

        // 2. Brief delay for the overlay window to fully disappear from the window server.
        overlay.dismiss()
        try? await Task.sleep(for: .milliseconds(100))

        // 3. Capture the full screen via ScreenCaptureKit.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            #if DEBUG
            print("[DEBUG ScreenCapture] SCShareableContent failed: \(error.localizedDescription)")
            #endif
            return nil
        }

        let scDisplay = content.displays.first { display in
            if let displayID = screenInfo.displayID { return display.displayID == displayID }
            return display.width == Int(screenInfo.frame.width)
                && display.height == Int(screenInfo.frame.height)
        }

        guard let scDisplay else {
            #if DEBUG
            print("[DEBUG ScreenCapture] no matching SCDisplay for screen '\(screenInfo.localizedName)'")
            #endif
            return nil
        }

        let scale = screenInfo.backingScaleFactor
        let config = SCStreamConfiguration()
        config.width = scDisplay.width * Int(scale)
        config.height = scDisplay.height * Int(scale)
        config.showsCursor = false

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])

        let fullImage: CGImage
        do {
            fullImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            #if DEBUG
            print("[DEBUG ScreenCapture] SCScreenshotManager.captureImage failed: \(error.localizedDescription)")
            #endif
            return nil
        }

        #if DEBUG
        print("[DEBUG ScreenCapture] full screen captured: \(fullImage.width)x\(fullImage.height)")
        #endif

        // 4. Convert selected rect from NSScreen coordinates to pixel coordinates
        //    within the captured image.
        //
        //    NSScreen coordinates: bottom-left origin, in points.
        //    CGImage pixel space: top-left origin, in pixels (points * scale).
        //
        //    The selected rect is in global screen coordinates. We need it relative
        //    to the target screen's origin, then flip Y for top-left origin, then
        //    scale to pixels.
        let screenFrame = screenInfo.frame

        let relativeX = selectedRect.origin.x - screenFrame.origin.x
        let relativeY = selectedRect.origin.y - screenFrame.origin.y

        // Flip Y: NSScreen is bottom-left, CGImage is top-left.
        let flippedY = screenFrame.height - relativeY - selectedRect.height

        let cropRect = CGRect(
            x: relativeX * scale,
            y: flippedY * scale,
            width: selectedRect.width * scale,
            height: selectedRect.height * scale
        )

        guard let croppedImage = fullImage.cropping(to: cropRect) else {
            #if DEBUG
            print("[DEBUG ScreenCapture] CGImage.cropping failed — cropRect=\(cropRect), imageSize=\(fullImage.width)x\(fullImage.height)")
            #endif
            return nil
        }

        #if DEBUG
        print("[DEBUG ScreenCapture] cropped to \(croppedImage.width)x\(croppedImage.height)")
        #endif

        return ScreenCaptureResult(image: croppedImage, capturedRect: selectedRect)
    }
}
