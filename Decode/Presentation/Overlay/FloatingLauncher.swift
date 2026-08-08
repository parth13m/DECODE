import AppKit
import SwiftUI

// MARK: - Launcher State

/// Observable state driving the launcher's continuous morph animation.
///
/// Uses two independent progress values instead of a boolean so the
/// controller can stagger timing differently for expand vs collapse.
@Observable
@MainActor
final class LauncherState {
    /// 0 → 1: main circle morph (size, position, opacity, glow).
    var mainProgress: CGFloat = 0
    /// 0 → 1: action buttons emerge / retract.
    var buttonsProgress: CGFloat = 0

    var isExpanded: Bool { mainProgress > 0.01 }
}

// MARK: - Floating Launcher

/// Non-activating floating panel that lives on the left edge of the screen.
///
/// The panel is always the expanded size (160×200). When collapsed, the panel
/// is positioned so only a sliver peeks on-screen. On hover, it slides out
/// and the SwiftUI content morphs from a half-circle to a full launcher.
/// This avoids window resizing — only position changes — producing a fluid,
/// continuous feel.
@MainActor
final class FloatingLauncher {

    // MARK: - Configuration

    /// Full panel dimensions (accommodates expanded circle + action buttons).
    private static let panelWidth: CGFloat = 132
    private static let panelHeight: CGFloat = 164
    /// How many pixels of the panel peek on-screen when collapsed.
    private static let peekAmount: CGFloat = 22
    /// Delay before collapsing after mouse exit.
    private static let collapseDelay: TimeInterval = 0.45

    // MARK: - State

    private var panel: LauncherPanel?
    private var isVisible = false
    let state = LauncherState()
    private var collapseWorkItem: DispatchWorkItem?
    private var anchorCenterY: CGFloat = 0
    /// Guards against re-entrant expand/collapse during animation.
    private var isAnimating = false

    // MARK: - Callbacks

    var onAddFile: (() -> Void)?
    var onAddFolder: (() -> Void)?
    var onLauncherTapped: (() -> Void)?

    // MARK: - Show / Hide

    func show() {
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }

        setDefaultAnchor()
        state.mainProgress = 0
        state.buttonsProgress = 0
        panel.setFrame(collapsedFrame(), display: true)
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        panel?.orderOut(nil)
        isVisible = false
        state.mainProgress = 0
        state.buttonsProgress = 0
        isAnimating = false
    }

    // MARK: - Expand

    private func expand() {
        guard !state.isExpanded, isVisible, !isAnimating else { return }
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        isAnimating = true

        // Slide the panel out — smooth position animation (NOT resize).
        guard let panel else { return }
        let target = expandedFrame()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.25, 1.0, 0.5, 1.0  // ease-out with slight overshoot feel
            )
            panel.animator().setFrame(target, display: true)
        }

        // Phase 1: Main circle morph — immediate, smooth spring.
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            state.mainProgress = 1.0
        }

        // Phase 2: Action buttons emerge — delayed, bouncier spring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) {
                self.state.buttonsProgress = 1.0
            }
            self.isAnimating = false
        }
    }

    // MARK: - Collapse

    private func collapse() {
        guard state.isExpanded, isVisible, !isAnimating else { return }
        isAnimating = true

        // Phase 1: Buttons retract — immediate, quick spring.
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            state.buttonsProgress = 0
        }

        // Phase 2: Main circle shrinks — slightly delayed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }

            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                self.state.mainProgress = 0
            }

            // Phase 3: Slide panel back into the edge.
            guard let panel = self.panel else { return }
            let target = self.collapsedFrame()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in
                self?.isAnimating = false
            })
        }
    }

    private func scheduleCollapse() {
        collapseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.collapse()
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: work)
    }

    private func cancelCollapse() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    // MARK: - Frame Calculations

    private func collapsedFrame() -> NSRect {
        let screenLeft = screenLeftX()
        return NSRect(
            x: screenLeft - (Self.panelWidth - Self.peekAmount),
            y: anchorCenterY - Self.panelHeight / 2,
            width: Self.panelWidth,
            height: Self.panelHeight
        )
    }

    private func expandedFrame() -> NSRect {
        let screenLeft = screenLeftX()
        return NSRect(
            x: screenLeft,
            y: anchorCenterY - Self.panelHeight / 2,
            width: Self.panelWidth,
            height: Self.panelHeight
        )
    }

    private func screenLeftX() -> CGFloat {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return 0 }
        return screen.visibleFrame.minX
    }

    private func setDefaultAnchor() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        anchorCenterY = screen.visibleFrame.midY
    }

    // MARK: - Panel Construction

    private func makePanel() -> LauncherPanel {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .aqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let contentView = LauncherContentView(
            state: state,
            onMainTap: { [weak self] in
                self?.onLauncherTapped?()
            },
            onAddFile: { [weak self] in
                self?.onAddFile?()
                // Collapse after a short pause so the click feels acknowledged.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.collapse()
                }
            },
            onAddFolder: { [weak self] in
                self?.onAddFolder?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.collapse()
                }
            }
        )
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let trackingContainer = LauncherTrackingView()
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

        return panel
    }
}

// MARK: - Launcher Panel

private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Tracking View

private final class LauncherTrackingView: NSView {
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

// MARK: - SwiftUI Content View

/// Single persistent view that morphs continuously between collapsed and
/// expanded states. No view swapping — all elements are always in the
/// hierarchy; only their animatable properties change.
private struct LauncherContentView: View {

    let state: LauncherState
    let onMainTap: () -> Void
    let onAddFile: () -> Void
    let onAddFolder: () -> Void

    // Decode palette
    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)
    private let glassBorder = Color.white.opacity(0.22)

    // MARK: - Derived Animation Values

    /// Main circle diameter: 42 → 52.
    private var mainSize: CGFloat { 42 + 10 * state.mainProgress }
    /// Main circle opacity: 0.22 → 1.0.
    private var mainOpacity: Double { 0.22 + 0.78 * state.mainProgress }
    /// Main circle X position within the 132-wide panel.
    /// Collapsed: circle centered at x=110 (near right edge of panel, since panel is off-screen left).
    /// Expanded: circle centered at x=36.
    private var mainX: CGFloat { 110 - 74 * state.mainProgress }
    /// Main circle Y position — always vertically centered.
    private var mainY: CGFloat { 82 }
    /// Icon opacity: 0.4 → 1.0.
    private var iconOpacity: Double { 0.4 + 0.6 * state.mainProgress }
    /// Icon size: 12 → 16.
    private var iconSize: CGFloat { 12 + 4 * state.mainProgress }
    /// Glow radius: 0 → 11.
    private var glowRadius: CGFloat { 11 * state.mainProgress }
    /// Shadow radius: 3 → 8.
    private var shadowRadius: CGFloat { 3 + 5 * state.mainProgress }
    /// Border opacity: 0.15 → 0.3.
    private var borderOpacity: Double { 0.15 + 0.15 * state.mainProgress }

    // Action button derived values
    private var buttonScale: CGFloat { 0.35 + 0.65 * state.buttonsProgress }
    private var buttonOpacity: Double { Double(state.buttonsProgress) }
    /// Buttons emerge from the main circle center outward.
    private var folderX: CGFloat { mainX + 56 * state.buttonsProgress }
    private var folderY: CGFloat { mainY - 48 * state.buttonsProgress }
    private var fileX: CGFloat { mainX + 56 * state.buttonsProgress }
    private var fileY: CGFloat { mainY + 48 * state.buttonsProgress }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Main launcher circle — always present
            Button(action: onMainTap) {
                ZStack {
                    // Glass circle
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(borderOpacity), lineWidth: 0.5)
                        )
                        // Orange glow — fades in during expansion
                        .shadow(color: accentOrange.opacity(0.12 * state.mainProgress), radius: glowRadius, x: 0, y: 0)
                        // Soft shadow
                        .shadow(color: .black.opacity(0.06 + 0.06 * state.mainProgress), radius: shadowRadius, x: 1, y: 2)

                    // Decode icon
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: iconSize, weight: .bold))
                        .foregroundStyle(accentOrange.opacity(iconOpacity))
                }
                .frame(width: mainSize, height: mainSize)
            }
            .buttonStyle(.plain)
            .opacity(mainOpacity)
            .position(x: mainX, y: mainY)

            // Add Folder — upper right of main circle
            actionButton(
                icon: "folder.badge.plus",
                label: "Folder",
                action: onAddFolder
            )
            .scaleEffect(buttonScale)
            .opacity(buttonOpacity)
            .position(x: folderX, y: folderY)

            // Add File — lower right of main circle
            actionButton(
                icon: "doc.badge.plus",
                label: "File",
                action: onAddFile
            )
            .scaleEffect(buttonScale)
            .opacity(buttonOpacity)
            .position(x: fileX, y: fileY)
        }
        .frame(width: 132, height: 164)
    }

    // MARK: - Action Button

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.06), radius: 4, x: 1, y: 2)

                VStack(spacing: 1) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accentOrange)
                    Text(label)
                        .font(.system(size: 6.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 35, height: 35)
        }
        .buttonStyle(.plain)
    }
}
