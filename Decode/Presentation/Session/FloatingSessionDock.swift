import AppKit
import SwiftUI

/// Shared observable state for the dock's expand/collapse and magnification.
@Observable
@MainActor
final class DockState {
    /// Whether the dock is expanded (showing workspace list) or collapsed (showing handle).
    var isExpanded = false
    /// Index of the currently hovered workspace pill, for magnification effect.
    var hoveredIndex: Int? = nil
}

/// Non-activating floating panel that shows open workspaces as a hover-reveal dock.
///
/// ## Design
/// No container background. Workspaces appear as individual floating capsule pills
/// with `.ultraThinMaterial` backdrops, anchored to the right edge of the screen.
/// A capsule handle is visible when collapsed. Hover reveals the pill stack.
///
/// ## Positioning
/// Vertical-only repositioning — the dock is always pinned to the right edge.
/// Only the Y coordinate is persisted between launches.
///
/// ## Interaction
/// Uses `NSTrackingArea` with `.activeAlways` for hover detection — works even
/// when Decode is not the active app. The panel uses `.nonactivatingPanel` so it
/// never steals focus from the editor.
@MainActor
final class FloatingSessionDock {

    // MARK: - Configuration

    static let dockWidth: CGFloat = 200
    static let handleWidth: CGFloat = 14
    static let handleHeight: CGFloat = 44
    static let maxDockHeight: CGFloat = 500

    /// Extra transparent margin on each side of the panel to prevent
    /// hover magnification from being clipped by the panel/ScrollView bounds.
    /// Pills lay out within the central `dockWidth` region; the overflow
    /// is invisible (no background) and exists solely for scale headroom.
    static let overflowMargin: CGFloat = 24

    private static let edgeInset: CGFloat = 4
    private static let collapseDelay: TimeInterval = 0.35
    private static let animationDuration: TimeInterval = 0.2
    private static let positionDefaultsKey = "sessionDockPosition"
    private static let pillHeight: CGFloat = 42
    private static let pillSpacing: CGFloat = 6

    // MARK: - State

    private var panel: DockPanel?
    private var isVisible = false
    let dockState = DockState()
    private var collapseWorkItem: DispatchWorkItem?

    /// Anchor point: the X coordinate of the dock's right edge and the Y center.
    /// Both collapsed and expanded frames are derived from this anchor so the
    /// right edge stays fixed as the dock expands left.
    private var anchorRightX: CGFloat = 0
    private var anchorCenterY: CGFloat = 0

    // MARK: - Callbacks

    /// Called when the user selects "Open Session Mode" from the context menu.
    /// Receives the workspace ID to activate.
    var onOpenSessionMode: ((UUID) -> Void)?

    // MARK: - Dependencies

    private let workspaceManager: WorkspaceManager

    // MARK: - Init

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    // MARK: - Show / Hide

    /// Show the dock if there are workspaces, or hide it if there are none.
    func updateVisibility() {
        if workspaceManager.workspaces.isEmpty {
            hide()
        } else if !isVisible {
            show()
        }
    }

    /// Show the dock in collapsed (handle) state.
    func show() {
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }

        if let saved = loadSavedPosition() {
            anchorRightX = saved.x
            anchorCenterY = saved.y
        } else {
            setDefaultAnchor()
        }

        dockState.isExpanded = false
        dockState.hoveredIndex = nil
        panel.setFrame(collapsedFrame(), display: true)
        panel.orderFrontRegardless()
        isVisible = true
    }

    /// Hide the dock panel entirely.
    func hide() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        savePosition()
        panel?.orderOut(nil)
        isVisible = false
        dockState.isExpanded = false
        dockState.hoveredIndex = nil
    }

    // MARK: - Expand / Collapse

    /// Expand the dock from the handle to the full workspace list.
    func expand() {
        guard !dockState.isExpanded, isVisible else { return }
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        dockState.isExpanded = true

        guard let panel else { return }
        let target = expandedFrame()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    /// Collapse the dock back to the handle.
    func collapse() {
        guard dockState.isExpanded, isVisible else { return }
        dockState.hoveredIndex = nil

        guard let panel else { return }
        let target = collapsedFrame()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            self?.dockState.isExpanded = false
        })
    }

    /// Schedule a collapse after the delay. Canceled if the mouse re-enters.
    private func scheduleCollapse() {
        collapseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.collapse()
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: work)
    }

    /// Cancel any pending collapse (mouse re-entered the dock area).
    private func cancelCollapse() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    // MARK: - Frame Calculations

    private func collapsedFrame() -> NSRect {
        NSRect(
            x: anchorRightX - Self.handleWidth,
            y: anchorCenterY - Self.handleHeight / 2,
            width: Self.handleWidth,
            height: Self.handleHeight
        )
    }

    private func expandedFrame() -> NSRect {
        let height = expandedHeight()
        let totalWidth = Self.dockWidth + 2 * Self.overflowMargin
        return NSRect(
            x: anchorRightX - Self.dockWidth - Self.overflowMargin,
            y: anchorCenterY - height / 2,
            width: totalWidth,
            height: height
        )
    }

    private func expandedHeight() -> CGFloat {
        let count = CGFloat(workspaceManager.workspaces.count)
        // Each pill + spacing between them + vertical overflow padding (top + bottom)
        let contentHeight = count * Self.pillHeight + max(0, count - 1) * Self.pillSpacing + 2 * Self.overflowMargin
        return min(contentHeight, Self.maxDockHeight)
    }

    // MARK: - Default Anchor

    private func setDefaultAnchor() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        anchorRightX = visible.maxX - Self.edgeInset
        anchorCenterY = visible.midY
    }

    /// Pin the X anchor to the right edge of the current screen.
    /// Called after every drag to enforce vertical-only repositioning.
    private func snapAnchorXToRightEdge() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        anchorRightX = screen.visibleFrame.maxX - Self.edgeInset
    }

    // MARK: - Panel Construction

    private func makePanel() -> DockPanel {
        let panel = DockPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.handleWidth, height: Self.handleHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        // Focus prevention — never steal focus from the editor.
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false

        // Appearance
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .aqua)

        // Spaces: visible on all Spaces including fullscreen.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // SwiftUI content
        let contentView = SessionDockContentView(
            workspaceManager: workspaceManager,
            dockState: dockState,
            onActivateWorkspace: { [weak self] id in
                self?.workspaceManager.activateWorkspace(id: id)
            },
            onCloseWorkspace: { [weak self] id in
                self?.workspaceManager.closeWorkspace(id: id)
                self?.updateVisibility()
            },
            onOpenSessionMode: { [weak self] id in
                self?.workspaceManager.activateWorkspace(id: id)
                self?.onOpenSessionMode?(id)
            },
            onTogglePin: { [weak self] id in
                guard let manager = self?.workspaceManager else { return }
                if manager.pinnedWorkspaceId == id {
                    manager.unpinWorkspace()
                } else {
                    manager.pinWorkspace(id: id)
                }
            }
        )
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        // Tracking container: detects mouse enter/exit for expand/collapse.
        let trackingContainer = TrackingContainerView()
        trackingContainer.translatesAutoresizingMaskIntoConstraints = false
        trackingContainer.onMouseEntered = { [weak self] in
            self?.cancelCollapse()
            self?.expand()
        }
        trackingContainer.onMouseExited = { [weak self] in
            self?.scheduleCollapse()
        }

        trackingContainer.addSubview(hostingView)
        panel.contentView = trackingContainer

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: trackingContainer.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: trackingContainer.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: trackingContainer.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trackingContainer.trailingAnchor),
        ])

        // Save position when user drags — vertical only.
        // X is always pinned to the right edge of the screen.
        panel.onMove = { [weak self] in
            guard let self, let panel = self.panel else { return }
            // Update only Y from the drag. Recompute X from screen edge.
            self.anchorCenterY = panel.frame.midY
            self.snapAnchorXToRightEdge()
            // Snap the panel back to the right edge immediately.
            let target = self.dockState.isExpanded
                ? self.expandedFrame()
                : self.collapsedFrame()
            panel.setFrame(target, display: true)
            self.savePosition()
        }

        return panel
    }

    // MARK: - Position Persistence

    private func savePosition() {
        guard isVisible else { return }
        // Only persist Y — X is always derived from the screen's right edge.
        UserDefaults.standard.set(Double(anchorCenterY), forKey: Self.positionDefaultsKey)
    }

    private func loadSavedPosition() -> NSPoint? {
        let savedY = UserDefaults.standard.double(forKey: Self.positionDefaultsKey)
        guard savedY != 0 else { return nil }

        // Derive X from current screen edge.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let x = screen.visibleFrame.maxX - Self.edgeInset

        let point = NSPoint(x: x, y: savedY)
        // Verify Y is on a visible screen.
        let isOnScreen = NSScreen.screens.contains { $0.frame.minY <= savedY && savedY <= $0.frame.maxY }
        return isOnScreen ? point : nil
    }
}

// MARK: - Dock Panel

/// NSPanel subclass that allows becoming key (for click handling) and
/// reports move events for position persistence.
private final class DockPanel: NSPanel {
    var onMove: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        onMove?()
    }
}

// MARK: - Tracking Container

/// Transparent wrapper view that detects mouse enter/exit via NSTrackingArea.
///
/// Uses `.activeAlways` so hover detection works even when Decode is not active.
/// Uses `.inVisibleRect` so the tracking area auto-adjusts when the panel resizes
/// during expand/collapse animation.
private final class TrackingContainerView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}
