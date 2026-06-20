import AppKit
import SwiftUI

/// Lightweight non-activating toast notification for operational feedback.
///
/// Displays a small overlay in the top-right corner of the active screen.
/// Auto-dismisses after 4 seconds with a fade animation. Each new toast
/// replaces the previous one — no stacking, no queue.
///
/// Used for transient messages that don't belong in the explanation HUD:
/// permission errors, empty selections, quota limits, capture failures.
@MainActor
final class DecodeToastManager {

    // MARK: - Configuration

    private static let toastWidth: CGFloat = 360
    private static let screenInset: CGFloat = 16
    private static let displayDuration: TimeInterval = 4.0
    private static let fadeDuration: TimeInterval = 0.25

    // MARK: - State

    private var panel: NSPanel?
    private var hostingView: NSHostingView<DecodeToastView>?
    private var dismissTask: Task<Void, Never>?
    private let viewModel = ToastViewModel()

    // MARK: - Public Interface

    /// Show a toast notification with an SF Symbol icon and message.
    ///
    /// Replaces any currently visible toast. Auto-dismisses after 4 seconds.
    func show(_ message: String, icon: String = "info.circle") {
        #if DEBUG
        print("[DEBUG Toast] show: \(message)")
        #endif

        // Cancel any pending dismiss.
        dismissTask?.cancel()

        // Update content.
        viewModel.message = message
        viewModel.icon = icon

        // Create panel if needed.
        if panel == nil {
            let (newPanel, newHostingView) = makePanel()
            panel = newPanel
            hostingView = newHostingView
        }

        guard let panel, let hostingView else { return }

        // Measure the SwiftUI content's intrinsic height at the fixed width,
        // then resize the panel to fit. This ensures multi-line messages
        // expand the toast vertically instead of being clipped.
        let fittingSize = hostingView.fittingSize
        let contentHeight = max(fittingSize.height, 44)
        panel.setContentSize(NSSize(width: Self.toastWidth, height: contentHeight))

        positionPanel(panel)

        // Fade in.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }

        // Schedule auto-dismiss.
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(Self.displayDuration))
            if !Task.isCancelled {
                dismiss()
            }
        }
    }

    /// Dismiss the current toast with a fade-out animation.
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil

        guard let panel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        })
    }

    // MARK: - Panel Management

    private func makePanel() -> (NSPanel, NSHostingView<DecodeToastView>) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.toastWidth, height: 44),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Non-activating, floating, no chrome.
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .aqua)

        let hosting = NSHostingView(
            rootView: DecodeToastView(viewModel: viewModel)
        )
        panel.contentView = hosting

        return (panel, hosting)
    }

    /// Position the toast in the top-right corner of the screen containing
    /// the mouse cursor, inset from the menu bar.
    private func positionPanel(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main ?? NSScreen.screens.first

        guard let screen = targetScreen else { return }

        let visibleFrame = screen.visibleFrame
        let panelHeight = panel.frame.height
        let x = visibleFrame.maxX - Self.toastWidth - Self.screenInset
        let y = visibleFrame.maxY - panelHeight - Self.screenInset

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Toast ViewModel

@Observable
@MainActor
final class ToastViewModel {
    var message: String = ""
    var icon: String = "info.circle"
}

// MARK: - Toast View

/// SwiftUI view for the toast notification.
///
/// Compact pill with an SF Symbol icon and a message that wraps to
/// two lines if needed. Matches the Decode HUD's visual language:
/// warm off-white background, thin beige border, orange accent icon.
struct DecodeToastView: View {

    // Decode accent — matches HUD's accentOrange.
    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)

    @Bindable var viewModel: ToastViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: viewModel.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accentOrange)

            Text(viewModel.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 360, alignment: .leading)
        .background(Color(red: 0.99, green: 0.98, blue: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(red: 0.91, green: 0.90, blue: 0.88), lineWidth: 0.5)
        )
    }
}
