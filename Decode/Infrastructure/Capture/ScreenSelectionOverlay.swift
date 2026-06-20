import AppKit
import CoreGraphics

/// Presents a fullscreen transparent overlay for drag-to-select screen region capture.
///
/// Uses the same non-activating panel presentation model as ``FloatingExplanationHUD``:
/// `NSPanel` + `.nonactivatingPanel` + `orderFrontRegardless()`. This avoids the
/// activation requirement that prevented the overlay from appearing on fullscreen Spaces.
///
/// Escape handling uses a global NSEvent monitor (same pattern as ``HotkeyService``)
/// instead of the responder chain, since the panel may not be the key window.
@MainActor
final class ScreenSelectionOverlay {

    /// Minimum drag distance (points) in either dimension to count as a valid selection.
    private static let minimumSelectionSize: CGFloat = 5

    private var overlayPanel: SelectionOverlayPanel?

    /// Global monitor for Escape key — works even when Decode is not active.
    private var globalEscapeMonitor: Any?
    /// Local monitor for Escape key — works when Decode is active.
    private var localEscapeMonitor: Any?

    /// Show the overlay on the screen containing the mouse cursor and wait for
    /// the user to drag-select a region.
    ///
    /// Returns `nil` if the user cancels (Escape) or the selection is too small.
    func selectRegion() async -> SelectionResult? {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main ?? NSScreen.screens.first

        guard let targetScreen else {
            #if DEBUG
            print("[DEBUG SelectionOverlay] no screen found")
            #endif
            return nil
        }

        let screenFrame = targetScreen.frame

        // Capture screen properties before the continuation to avoid sending
        // NSScreen (non-Sendable) across the isolation boundary.
        let screenInfo = ScreenInfo(
            frame: targetScreen.frame,
            backingScaleFactor: targetScreen.backingScaleFactor,
            localizedName: targetScreen.localizedName,
            displayID: targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        )

        let selectedRect: CGRect? = await withCheckedContinuation { continuation in
            var hasResumed = false

            let complete: (CGRect?) -> Void = { [weak self] rect in
                guard !hasResumed else { return }
                hasResumed = true
                self?.removeEscapeMonitors()
                self?.overlayPanel?.orderOut(nil)
                continuation.resume(returning: rect)
            }

            let panel = SelectionOverlayPanel(screenFrame: screenFrame) { [weak self] rectInView in
                guard let self, let panel = self.overlayPanel else {
                    complete(nil)
                    return
                }

                // Convert view-local rect to screen coordinates.
                if let rectInView {
                    let screenRect = panel.convertToScreen(rectInView)
                    panel.orderOut(nil)
                    complete(screenRect)
                } else {
                    panel.orderOut(nil)
                    complete(nil)
                }
            }

            self.overlayPanel = panel

            // Install Escape monitors before showing the panel.
            // Global monitor: receives Escape when another app is active (fullscreen).
            // Local monitor: receives Escape when Decode is active.
            self.globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { complete(nil) }
            }
            self.localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    complete(nil)
                    return nil  // Consume
                }
                return event
            }

            panel.orderFrontRegardless()
            panel.makeFirstResponder(panel.contentView)
        }

        // Validate minimum size.
        guard let rect = selectedRect,
              rect.width >= Self.minimumSelectionSize,
              rect.height >= Self.minimumSelectionSize
        else {
            return nil
        }

        return SelectionResult(
            screenInfo: screenInfo,
            rectInScreenCoordinates: rect
        )
    }

    /// Dismiss the overlay panel and remove monitors.
    func dismiss() {
        removeEscapeMonitors()
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
    }

    private func removeEscapeMonitors() {
        if let monitor = globalEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            globalEscapeMonitor = nil
        }
        if let monitor = localEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            localEscapeMonitor = nil
        }
    }

    /// Sendable snapshot of the properties we need from NSScreen.
    struct ScreenInfo: Sendable {
        let frame: CGRect
        let backingScaleFactor: CGFloat
        let localizedName: String
        let displayID: CGDirectDisplayID?
    }

    /// The result of a successful region selection.
    struct SelectionResult: Sendable {
        /// Properties of the screen the selection was made on.
        let screenInfo: ScreenInfo
        /// The selected rectangle in NSScreen coordinates (bottom-left origin).
        let rectInScreenCoordinates: CGRect
    }
}

// MARK: - Overlay Panel

/// Non-activating borderless panel for the selection overlay.
///
/// Uses `.nonactivatingPanel` so the panel appears without activating Decode.
/// Uses `.screenSaver` level to appear above all user windows including fullscreen apps.
/// Uses `orderFrontRegardless()` to bypass activation requirements entirely.
@MainActor
private final class SelectionOverlayPanel: NSPanel {

    init(screenFrame: CGRect, onComplete: @escaping (CGRect?) -> Void) {
        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let overlayView = SelectionOverlayView(
            frame: NSRect(origin: .zero, size: screenFrame.size),
            onComplete: onComplete
        )

        contentView = overlayView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay View

/// Handles mouse drag selection within the overlay.
///
/// Drawing:
/// - Semi-transparent dark scrim over the entire view
/// - Clear cutout for the selected region
/// - White border around the selection
/// - Dimension label showing WxH in points
///
/// Escape handling is done via NSEvent monitors in ``ScreenSelectionOverlay``,
/// not through the responder chain, so this view does not override `keyDown`.
@MainActor
private final class SelectionOverlayView: NSView {

    private let onComplete: (NSRect?) -> Void

    /// The anchor point where the drag started (view coordinates).
    private var dragOrigin: NSPoint?
    /// The current selection rectangle (view coordinates).
    private var selectionRect: NSRect?

    init(frame: NSRect, onComplete: @escaping (NSRect?) -> Void) {
        self.onComplete = onComplete
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // 1. Semi-transparent scrim over entire view.
        NSColor(white: 0, alpha: 0.3).setFill()
        bounds.fill()

        guard let selection = selectionRect, selection.width > 0, selection.height > 0 else {
            return
        }

        // 2. Clear cutout for the selection (punch through the scrim).
        NSColor.clear.setFill()
        selection.fill(using: .copy)

        // 3. White border around the selection.
        NSColor.white.setStroke()
        let borderPath = NSBezierPath(rect: selection)
        borderPath.lineWidth = 1.5
        borderPath.stroke()

        // 4. Dimension label.
        let label = "\(Int(selection.width)) x \(Int(selection.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor(white: 0, alpha: 0.6),
        ]
        let labelSize = label.size(withAttributes: attrs)

        // Position label below the selection, or above if there's no room below.
        let labelPadding: CGFloat = 4
        var labelOrigin = NSPoint(
            x: selection.midX - labelSize.width / 2,
            y: selection.minY - labelSize.height - labelPadding
        )
        if labelOrigin.y < bounds.minY {
            labelOrigin.y = selection.maxY + labelPadding
        }

        label.draw(at: labelOrigin, withAttributes: attrs)
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        // Escape key (keyCode 53). Handles the case where neither the global
        // nor local NSEvent monitor fires — e.g., a .nonactivatingPanel at
        // .screenSaver level where the app activation state is ambiguous.
        if event.keyCode == 53 {
            onComplete(nil)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragOrigin = point
        selectionRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let current = convert(event.locationInWindow, from: nil)
        selectionRect = rectFromPoints(origin, current)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onComplete(selectionRect)
    }

    // MARK: - Helpers

    /// Build a normalized rect from two arbitrary corner points.
    private func rectFromPoints(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }
}
