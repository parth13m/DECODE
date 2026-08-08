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
    private static let intentPanelHeight: CGFloat = 90
    private static let panelMinWidth: CGFloat = 350
    private static let panelMinHeight: CGFloat = 80
    private static let panelMaxWidth: CGFloat = 1200
    private static let panelMaxHeight: CGFloat = 1200
    private static let cornerRadius: CGFloat = 12

    // MARK: - State

    let viewModel = ExplanationHUDViewModel()
    private var panel: NSPanel?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    // MARK: - Public Interface

    /// Show the HUD with a streaming AI explanation.
    ///
    /// Creates the panel if needed, positions it on the active screen,
    /// and begins consuming tokens from the stream.
    func showStream(
        _ stream: AsyncThrowingStream<String, Error>,
        sourceApp: String?,
        followUpContext: ExplanationHUDViewModel.FollowUpContext? = nil,
        onComplete: (@MainActor (String) -> Void)? = nil
    ) {
        #if DEBUG
        print("[DEBUG HUD] showStream called, sourceApp=\(sourceApp ?? "nil")")
        #endif
        viewModel.showStream(stream, sourceApp: sourceApp, followUpContext: followUpContext, onComplete: onComplete)
        panel?.setContentSize(NSSize(width: Self.panelWidth, height: Self.panelHeight))
        ensurePanelVisible()
    }

    /// Show the HUD immediately in loading state before the AI request starts.
    ///
    /// Call this before `await provider.streamChat()` so the user sees immediate
    /// feedback. When the stream is ready, call ``showStream(_:sourceApp:followUpContext:)``
    /// which transitions from loading to streaming.
    func showLoading(sourceApp: String?, mode: String? = nil, sessionFile: String? = nil, explanationProfile: String? = nil, executionContext: ExplanationExecutionContext? = nil) {
        #if DEBUG
        print("[DEBUG HUD] showLoading called, sourceApp=\(sourceApp ?? "nil"), mode=\(mode ?? "nil")")
        #endif
        viewModel.showLoading(sourceApp: sourceApp, mode: mode, sessionFile: sessionFile, explanationProfile: explanationProfile, executionContext: executionContext)
        panel?.setContentSize(NSSize(width: Self.panelWidth, height: Self.panelHeight))
        ensurePanelVisible()
    }

    /// Show a standalone error message in the HUD.
    func showError(_ message: String) {
        #if DEBUG
        print("[DEBUG HUD] showError called — \(message)")
        #endif
        viewModel.showError(message)
        panel?.setContentSize(NSSize(width: Self.panelWidth, height: Self.panelHeight))
        ensurePanelVisible()
    }

    /// Show the HUD in intent collection state and wait for the user's input.
    ///
    /// Returns the user's text (empty = default explanation, non-empty = custom request),
    /// or `nil` if the user cancelled (Escape or close button).
    ///
    /// - Parameter onEditingStarted: One-shot callback fired when the user types the
    ///   first printable character (transitions from idle to editing). Coordinators use
    ///   this to start background work (e.g., vision extraction) only when a custom
    ///   question is being typed. Not called for Enter/Space/Escape.
    func collectIntent(
        sourceApp: String?,
        mode: String? = nil,
        sessionFile: String? = nil,
        explanationProfile: String? = nil,
        onEditingStarted: (@MainActor () -> Void)? = nil
    ) async -> String? {
        // Step 1: Set state synchronously so SwiftUI renders the intent input.
        viewModel.prepareIntentCollection(
            sourceApp: sourceApp,
            mode: mode,
            sessionFile: sessionFile,
            explanationProfile: explanationProfile
        )
        viewModel.onEditingStarted = onEditingStarted
        // Step 2: Show the panel at compact intent size.
        ensurePanelVisible()
        panel?.setContentSize(NSSize(width: Self.panelWidth, height: Self.intentPanelHeight))
        positionPanel(panel!)
        // Step 3: Make the panel key so keyboard events route here.
        panel?.makeKey()
        // Step 4: Install key event monitors so keyboard events work
        // immediately without requiring the user to click the panel.
        // A local monitor handles events when the app is active. A global
        // monitor handles events when another app is active (non-activating
        // panel scenario). Together they cover both cases.
        installIntentKeyMonitor()
        // Step 5: Suspend until the user submits or cancels.
        let result = await viewModel.awaitIntentSubmission()
        // Clean up the monitor.
        removeIntentKeyMonitor()
        // If cancelled, hide the panel.
        if result == nil {
            panel?.orderOut(nil)
        }
        return result
    }

    /// Dismiss the HUD and cancel any in-flight stream.
    func dismiss() {
        removeIntentKeyMonitor()
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

        // Reposition traffic lights downward for tighter grouping with content.
        // The default position sits them high in the titlebar, creating visual
        // disconnection from the floating intent bar.
        if let closeButton = panel.standardWindowButton(.closeButton),
           let titlebarContainer = closeButton.superview {
            var containerFrame = titlebarContainer.frame
            containerFrame.origin.y -= 6
            containerFrame.origin.x += 4
            titlebarContainer.frame = containerFrame
        }

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

    // MARK: - Intent Key Event Monitor

    /// Install event monitors that intercept keyDown events during intent
    /// collection. Two monitors cover both scenarios:
    ///
    /// - **Local monitor**: fires when Decode is the active application.
    ///   Can consume events (return nil) to prevent them reaching other views.
    /// - **Global monitor**: fires when another application is active
    ///   (the common case with `.nonactivatingPanel`). Cannot consume events
    ///   but can trigger ViewModel actions. Key presses may also reach the
    ///   underlying app, which is acceptable — the intent bar dismisses
    ///   immediately so the user never notices a stray keystroke.
    private func installIntentKeyMonitor() {
        removeIntentKeyMonitor()

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleIntentKeyEvent(event, canConsume: true)
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            _ = self.handleIntentKeyEvent(event, canConsume: false)
        }
    }

    /// Handle a key event during intent collection.
    /// Returns `nil` to consume the event (local monitor only), or the event to pass through.
    private func handleIntentKeyEvent(_ event: NSEvent, canConsume: Bool) -> NSEvent? {
        guard viewModel.displayState == .collectingIntent else {
            return event
        }

        // In editing state, let the TextField handle events normally —
        // except Escape, which we always intercept to cancel.
        if viewModel.isEditingIntent {
            if event.keyCode == 53 { // Escape
                viewModel.cancelIntent()
                dismiss()
                return canConsume ? nil : event
            }
            // Let the TextField process all other keys.
            return event
        }

        // STATE 1: Idle — intercept all relevant keys.
        switch event.keyCode {
        case 36, 76: // Return, Enter (numpad)
            viewModel.submitIntent()
            return canConsume ? nil : event
        case 49: // Space
            viewModel.submitIntent()
            return canConsume ? nil : event
        case 53: // Escape
            viewModel.cancelIntent()
            dismiss()
            return canConsume ? nil : event
        default:
            // Printable character → transition to editing.
            if let chars = event.characters, !chars.isEmpty {
                let c = chars.first!
                if !c.isNewline && !c.isWhitespace && (c.isLetter || c.isNumber || c.isPunctuation || c.isSymbol) {
                    // Transition to editing with empty text. The TextField
                    // will appear and gain focus with nothing to select.
                    viewModel.transitionToEditing()
                    panel?.makeKey()

                    // Re-post the original key event so the TextField
                    // receives it through the normal responder chain.
                    // This produces native text insertion — the character
                    // is typed into the field, cursor ends up after it,
                    // nothing is selected. The re-posted event will pass
                    // through the monitor's editing-state path (which
                    // returns the event for TextField processing).
                    DispatchQueue.main.async {
                        NSApp.postEvent(event, atStart: true)
                    }
                    return canConsume ? nil : event
                }
            }
            return event
        }
    }

    /// Remove event monitors.
    private func removeIntentKeyMonitor() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
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

    @FocusState private var isTextFieldFocused: Bool

    init(viewModel: ExplanationHUDViewModel, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
    }

    // WhisperFlow-inspired accent
    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)

    var body: some View {
        if viewModel.displayState == .collectingIntent {
            // Intent state: transparent panel, only the floating bar is visible.
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // All other states: standard HUD chrome.
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
                    .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
            )
        }
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

            // Execution context badge
            if let ctx = viewModel.executionContext {
                Text(ctx.displayText)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accentOrange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(accentOrange.opacity(0.12))
                    )
            } else if let mode = viewModel.modeName {
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

        case .collectingIntent:
            intentInputView

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

                    // MARK: Optimise & Note
                    if viewModel.displayState == .complete {
                        improveCodeSection
                    }

                    // MARK: Note
                    if viewModel.displayState == .complete {
                        noteSection
                    }

                    // MARK: Feedback
                    if let fm = viewModel.feedbackManager, fm.showingFeedback {
                        feedbackSection(manager: fm)
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

    // MARK: - Optimise Code

    @ViewBuilder
    private var improveCodeSection: some View {
        if viewModel.hasImprovementResult {
            // Show the full improvement section (loading, result, or error).
            ImprovementSectionView(viewModel: viewModel)
        } else if viewModel.canRequestImprovement {
            // Show the "Optimise" button with goal picker menu.
            Divider()
                .overlay(Color(red: 0.91, green: 0.90, blue: 0.88))
                .padding(.top, 4)

            Menu {
                ForEach(OptimisationGoal.allCases, id: \.self) { goal in
                    Button {
                        viewModel.requestImprovement(goal: goal)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("\(goal.icon) \(goal.displayName)")
                            Text(goal.description)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11))
                    Text("Optimise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(accentOrange)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.top, 2)
        }
    }

    // MARK: - Note

    @ViewBuilder
    private var noteSection: some View {
        if viewModel.canSaveNote && !viewModel.hasImprovementResult {
            HStack(spacing: 8) {
                Button {
                    viewModel.saveNote()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 11))
                        Text("Note")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(accentOrange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(accentOrange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                if !viewModel.noteSavedConfirmation.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.22, green: 0.65, blue: 0.36))
                        Text(viewModel.noteSavedConfirmation)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(red: 0.22, green: 0.65, blue: 0.36))
                    }
                }

                Spacer()
            }
        }
    }

    // MARK: - Feedback

    private func feedbackSection(manager: FeedbackManager) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .overlay(Color(red: 0.91, green: 0.90, blue: 0.88))
                .padding(.top, 4)

            if manager.feedbackSubmitted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.22, green: 0.65, blue: 0.36))
                    Text("Thanks for your feedback!")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    Text("Was this helpful?")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Button {
                        manager.submitFeedback(liked: true)
                    } label: {
                        HStack(spacing: 3) {
                            Text("\u{1F44D}")
                                .font(.system(size: 13))
                            Text("Helpful")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(red: 0.22, green: 0.65, blue: 0.36).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)

                    Button {
                        manager.submitFeedback(liked: false)
                    } label: {
                        HStack(spacing: 3) {
                            Text("\u{1F44E}")
                                .font(.system(size: 13))
                            Text("Not Helpful")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(red: 0.90, green: 0.30, blue: 0.24).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        manager.dismissFeedback()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Intent Input

    /// Decode warm white for the floating bar surface.
    private static let barSurface = Color(red: 0.99, green: 0.98, blue: 0.97)

    @ViewBuilder
    private var intentInputView: some View {
        if viewModel.isEditingIntent {
            intentEditingView
        } else {
            intentIdleView
        }
    }

    /// State 1: Container is focusable and owns all key events.
    /// Enter/Space → default explanation. Any printable character → State 2.
    /// Top padding to position the capsule bar below the traffic lights
    /// with a comfortable, intentional gap. The titlebar is ~28pt; this
    /// value places the bar so the two feel visually grouped.
    private static let intentTopPadding: CGFloat = 5

    private var intentIdleView: some View {
        VStack(spacing: 6) {
            // Floating capsule bar
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(accentOrange.opacity(0.7))

                Text("Help me understand this code…")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.leading, 18)
            .padding(.trailing, 20)
            .padding(.vertical, 13)
            .background(
                Capsule()
                    .fill(Self.barSurface)
            )
            .overlay(
                Capsule()
                    .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.03), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
            .shadow(color: .black.opacity(0.04), radius: 20, y: 8)

            // Hints — quiet, below the bar
            Text("enter · explain    space · explain    type · ask    esc · cancel")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .opacity(0.7)
        }
        .padding(.top, Self.intentTopPadding)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            viewModel.submitIntent()
            return .handled
        }
        .onKeyPress(.space) {
            viewModel.submitIntent()
            return .handled
        }
        .onKeyPress(.escape) {
            viewModel.cancelIntent()
            onDismiss()
            return .handled
        }
        .onKeyPress(characters: .alphanumerics
            .union(.punctuationCharacters)
            .union(.symbols),
                     phases: .down
        ) { keyPress in
            let char = keyPress.characters
            guard !char.isEmpty else { return .ignored }
            viewModel.beginEditing(with: char)
            return .handled
        }
    }

    /// State 2: TextField is focused and owns all keyboard input.
    /// Space inserts spaces. Enter submits the custom request.
    private var intentEditingView: some View {
        VStack(spacing: 6) {
            // Floating capsule bar — editing state
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(accentOrange)

                TextField("", text: $viewModel.intentText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        viewModel.submitIntent()
                    }

                Spacer(minLength: 0)
            }
            .padding(.leading, 18)
            .padding(.trailing, 20)
            .padding(.vertical, 13)
            .background(
                Capsule()
                    .fill(Self.barSurface)
            )
            .overlay(
                Capsule()
                    .stroke(accentOrange.opacity(0.2), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.03), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
            .shadow(color: .black.opacity(0.04), radius: 20, y: 8)

            // Hints — editing state
            Text("enter · submit    esc · cancel")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .opacity(0.7)
        }
        .padding(.top, Self.intentTopPadding)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onKeyPress(.escape) {
            viewModel.cancelIntent()
            onDismiss()
            return .handled
        }
        .onAppear {
            isTextFieldFocused = true
        }
        .onChange(of: viewModel.isEditingIntent) { _, editing in
            if editing {
                isTextFieldFocused = true
            }
        }
    }
}
