import AppKit
import SwiftUI

/// Non-activating floating panel for displaying AI-generated code explanations.
///
/// Manages the NSPanel lifecycle: creation, positioning, show/hide. Hosts a
/// SwiftUI ``HUDContentView`` inside the panel. Delegates content state
/// management to ``ExplanationHUDViewModel``.
///
/// ## Focus Behavior
/// The panel uses `.nonactivatingPanel` style mask and `.floating` level so it
/// never steals focus from the user's source application.
///
/// ## Multi-Monitor
/// Positions on the screen where the mouse cursor currently resides.
@MainActor
final class FloatingExplanationHUD {

    // MARK: - Configuration

    private static let panelWidth: CGFloat = 500
    private static let panelHeight: CGFloat = 200
    private static let panelMinWidth: CGFloat = 350
    private static let panelMinHeight: CGFloat = 150
    private static let panelMaxWidth: CGFloat = 1200
    private static let panelMaxHeight: CGFloat = 1200
    private static let cornerRadius: CGFloat = 12

    // MARK: - State

    let viewModel = ExplanationHUDViewModel()
    private var panel: NSPanel?

    // MARK: - Public Interface

    /// Show the HUD with a streaming AI explanation.
    ///
    /// Creates the panel if needed, positions it on the active screen,
    /// and begins consuming tokens from the stream.
    func showStream(
        _ stream: AsyncThrowingStream<String, Error>,
        sourceApp: String?,
        followUpContext: ExplanationHUDViewModel.FollowUpContext? = nil
    ) {
        #if DEBUG
        print("[DEBUG HUD] showStream called, sourceApp=\(sourceApp ?? "nil")")
        #endif
        viewModel.showStream(stream, sourceApp: sourceApp, followUpContext: followUpContext)
        ensurePanelVisible()
    }

    /// Show the HUD immediately in loading state before the AI request starts.
    ///
    /// Call this before `await provider.streamChat()` so the user sees immediate
    /// feedback. When the stream is ready, call ``showStream(_:sourceApp:followUpContext:)``
    /// which transitions from loading to streaming.
    func showLoading(sourceApp: String?, mode: String? = nil, sessionFile: String? = nil, explanationProfile: String? = nil) {
        #if DEBUG
        print("[DEBUG HUD] showLoading called, sourceApp=\(sourceApp ?? "nil"), mode=\(mode ?? "nil")")
        #endif
        viewModel.showLoading(sourceApp: sourceApp, mode: mode, sessionFile: sessionFile, explanationProfile: explanationProfile)
        ensurePanelVisible()
    }

    /// Show a standalone error message in the HUD.
    func showError(_ message: String) {
        #if DEBUG
        print("[DEBUG HUD] showError called — \(message)")
        #endif
        viewModel.showError(message)
        ensurePanelVisible()
    }

    /// Dismiss the HUD and cancel any in-flight stream.
    func dismiss() {
        viewModel.dismiss()
        panel?.orderOut(nil)
    }

    // MARK: - Panel Management

    private func ensurePanelVisible() {
        if panel == nil {
            panel = makePanel()
        }

        guard let panel else { return }

        positionPanel(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.panelWidth,
                height: Self.panelHeight
            ),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Focus prevention
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false

        // Appearance
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .aqua)

        // Size constraints
        panel.minSize = NSSize(width: Self.panelMinWidth, height: Self.panelMinHeight)
        panel.maxSize = NSSize(width: Self.panelMaxWidth, height: Self.panelMaxHeight)

        // Host SwiftUI content. Pass a dismiss closure so the SwiftUI ✕ button
        // can trigger the full panel-level dismiss (viewModel reset + orderOut).
        let hostingView = NSHostingView(
            rootView: HUDContentView(viewModel: viewModel) { [weak self] in
                self?.dismiss()
            }
        )
        panel.contentView = hostingView

        // Force the panel to the configured default size. Without this,
        // NSHostingView shrinks the panel to fit the SwiftUI content's
        // intrinsic size, which is tiny in loading/idle state.
        panel.setContentSize(NSSize(width: Self.panelWidth, height: Self.panelHeight))

        // Handle close button as dismiss
        panel.delegate = panelDelegate
        panelDelegate.onClose = { [weak self] in
            self?.dismiss()
        }

        return panel
    }

    /// Position the panel on the screen where the mouse cursor is,
    /// centered horizontally and offset from vertical center.
    private func positionPanel(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main ?? NSScreen.screens.first

        guard let screen = targetScreen else { return }

        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size

        let x = screenFrame.midX - (panelSize.width / 2)
        // Position slightly above center for comfortable reading
        let y = screenFrame.midY + (screenFrame.height * 0.1)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Panel Delegate

    private let panelDelegate = HUDPanelDelegate()
}

// MARK: - Keyable Panel

/// NSPanel subclass that allows becoming the key window.
///
/// A plain NSPanel with `.nonactivatingPanel` returns `false` from `canBecomeKey`,
/// which prevents all button clicks (SwiftUI buttons and native close button) from
/// being processed. This subclass overrides `canBecomeKey` to return `true` so that
/// interactive controls work while still preserving non-activating behavior.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Panel Delegate

/// Handles NSPanel close events, forwarding to the HUD's dismiss logic.
private final class HUDPanelDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - HUD Content View

/// SwiftUI content displayed inside the floating panel.
private struct HUDContentView: View {
    @Bindable var viewModel: ExplanationHUDViewModel
    var onDismiss: () -> Void

    init(viewModel: ExplanationHUDViewModel, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
    }

    // WhisperFlow-inspired accent
    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerView
            Divider()
                .overlay(Color(red: 0.91, green: 0.90, blue: 0.88))
            contentArea
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.99, green: 0.98, blue: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(red: 0.91, green: 0.90, blue: 0.88), lineWidth: 0.1)
        )
    }

    // MARK: - Header

    @ViewBuilder
    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accentOrange)

            // Title: prefer session file name in Session Mode, else source app name.
            if let sessionFile = viewModel.sessionFileName {
                Text("Explanation — \(sessionFile)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else if let appName = viewModel.sourceAppName {
                Text("Explanation — \(appName)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            } else {
                Text("Explanation")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            // Mode badge
            if let mode = viewModel.modeName {
                Text(Self.modeDisplayName(mode, profile: viewModel.explanationProfile))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accentOrange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(accentOrange.opacity(0.12))
                    )
            }

            Spacer()

            if viewModel.isStreaming {
                ProgressView()
                    .controlSize(.small)
                    .tint(accentOrange)
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private static func modeDisplayName(_ mode: String, profile: String? = nil) -> String {
        let modeName: String
        switch mode {
        case "session": modeName = "Session"
        case "selection": modeName = "Selection"
        case "screenshot": modeName = "Screenshot"
        default: modeName = mode.capitalized
        }

        let profileName: String
        switch profile {
        case "dsa": profileName = "DSA"
        default: profileName = "General"
        }

        return "\(modeName) · \(profileName)"
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        switch viewModel.displayState {
        case .idle:
            EmptyView()

        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(accentOrange)
                Text("Thinking...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

        case .streaming, .complete:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ExplanationTagParser.blocks(from: viewModel.explanationText)) { block in
                        switch block {
                        case .inlineRun(_, let segments):
                            Text(ExplanationTagParser.attributedString(from: segments))
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .tldr(_, let content):
                            TLDRBlockView(content: content)
                        case .flow(_, let content):
                            FlowBlockView(content: content)
                        case .codeBlock(_, let language, let code):
                            CodeBlockView(language: language, code: code)
                        case .table(_, let headers, let rows):
                            TableBlockView(headers: headers, rows: rows)
                        }
                    }

                    // Show error notice if stream was interrupted after partial content.
                    if !viewModel.errorMessage.isEmpty {
                        Label(viewModel.errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.top, 4)
                    }

                    // MARK: Follow-up Section
                    if viewModel.displayState == .complete {
                        followUpSection
                    }

                    // MARK: Improve Code
                    if viewModel.displayState == .complete {
                        improveCodeSection
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)

        case .error:
            Label(viewModel.errorMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(red: 0.90, green: 0.30, blue: 0.24))
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Follow-up

    @ViewBuilder
    private var followUpSection: some View {
        if viewModel.canAskFollowUp || !viewModel.followUpAnswer.isEmpty || viewModel.isFollowUpLoading {
            Divider()
                .overlay(Color(red: 0.91, green: 0.90, blue: 0.88))
                .padding(.top, 4)

            // Follow-up answer
            if !viewModel.followUpAnswer.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Follow-up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(ExplanationTagParser.blocks(from: viewModel.followUpAnswer)) { block in
                        switch block {
                        case .inlineRun(_, let segments):
                            Text(ExplanationTagParser.attributedString(from: segments))
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .tldr(_, let content):
                            TLDRBlockView(content: content)
                        case .flow(_, let content):
                            FlowBlockView(content: content)
                        case .codeBlock(_, let language, let code):
                            CodeBlockView(language: language, code: code)
                        case .table(_, let headers, let rows):
                            TableBlockView(headers: headers, rows: rows)
                        }
                    }
                }
            }

            // Follow-up error
            if !viewModel.followUpError.isEmpty {
                Label(viewModel.followUpError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.system(size: 11, weight: .medium))
            }

            // Follow-up loading
            if viewModel.isFollowUpLoading && viewModel.followUpAnswer.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accentOrange)
                    Text("Thinking...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            // Follow-up input
            if viewModel.canAskFollowUp || viewModel.isFollowUpLoading {
                HStack(spacing: 8) {
                    TextField("Ask a follow-up question...", text: $viewModel.followUpText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(red: 0.95, green: 0.94, blue: 0.93))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onSubmit {
                            viewModel.askFollowUp()
                        }
                        .disabled(viewModel.isFollowUpLoading)

                    Button {
                        viewModel.askFollowUp()
                    } label: {
                        Text("Ask")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(viewModel.canAskFollowUp ? accentOrange : Color.gray)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canAskFollowUp)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Improve Code

    @ViewBuilder
    private var improveCodeSection: some View {
        if viewModel.hasImprovementResult {
            // Show the full improvement section (loading, result, or error).
            ImprovementSectionView(viewModel: viewModel)
        } else if viewModel.canRequestImprovement {
            // Show the "Improve Code" button.
            Divider()
                .overlay(Color(red: 0.91, green: 0.90, blue: 0.88))
                .padding(.top, 4)

            Button {
                viewModel.requestImprovement()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 11))
                    Text("Improve Code")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(accentOrange)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }
}
