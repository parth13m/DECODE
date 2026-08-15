// FloatingHistoryHUD.swift — Decode Presentation
//
// The History HUD: a scrollable list of the user's 10 most recent
// explanation requests with their follow-up conversations. Supports
// code collapse/expand, text selection with Anchored Reply, and
// follow-up from the most recent request.
//
// Renders chronologically (oldest → newest) so the bottom of the list
// represents the user's latest investigation.
//
// Uses the same non-activating NSPanel pattern as FloatingExplanationHUD
// but is entirely independent — History never repurposes the Explanation HUD.

import AppKit
import SwiftUI

// MARK: - FloatingHistoryHUD

@MainActor
final class FloatingHistoryHUD {

    private var panel: NSPanel?
    let historyManager: HistoryManager

    /// AI provider closure for follow-ups from History.
    var aiProviderClosure: (@MainActor () -> (any AIProviderProtocol)?)?
    /// Usage tracker for follow-up billing.
    var usageTracker: AIUsageTracker?

    init(historyManager: HistoryManager) {
        self.historyManager = historyManager
    }

    // MARK: - Show / Hide / Toggle

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }
        if let savedFrame = HUDFramePersistence.loadFrame(for: .history) {
            panel.setFrame(savedFrame, display: true)
        } else {
            positionPanel(panel)
        }
        panel.orderFrontRegardless()
        panel.makeKey()

        AnalyticsEventService.send(eventType: "history_opened", mode: nil)
    }

    func hide() {
        if let panel, panel.isVisible {
            HUDFramePersistence.saveFrame(panel.frame, for: .history)
        }
        panel?.orderOut(nil)
    }

    // MARK: - Panel Construction

    private func makePanel() -> NSPanel {
        let panel = HistoryKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .aqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 380, height: 300)
        panel.maxSize = NSSize(width: 900, height: 1200)

        let contentView = HistoryContentView(
            historyManager: historyManager,
            aiProviderClosure: { [weak self] in self?.aiProviderClosure?() },
            usageTrackerClosure: { [weak self] in self?.usageTracker },
            onDismiss: { [weak self] in self?.hide() }
        )
        let hostingView = NSHostingView(rootView: contentView)
        panel.contentView = hostingView

        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.midY - panelSize.height / 2 + screenFrame.height * 0.05
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - History Content View

private struct HistoryContentView: View {
    @Bindable var historyManager: HistoryManager
    let aiProviderClosure: @MainActor () -> (any AIProviderProtocol)?
    let usageTrackerClosure: @MainActor () -> AIUsageTracker?
    let onDismiss: () -> Void

    @State private var followUpText: String = ""
    @State private var isFollowUpLoading: Bool = false
    @State private var followUpError: String = ""
    @State private var activeSelectionBlockID: SelectableBlockID?
    @State private var responseSelection: ResponseSelection?
    @State private var anchoredResponseSelection: ResponseSelection?
    @State private var replyActivated: Bool = false
    /// Tracks the UUID of the HistoryRequest that the pending/anchored
    /// selection originated from. When an anchored follow-up is submitted,
    /// this request — not necessarily the newest — provides the source context.
    @State private var selectionSourceRequestId: UUID?
    /// Tracks which follow-up within the source request the selection came from.
    /// `nil` means the selection is from the main explanation (no follow-ups included).
    /// A value of N means the selection is from follow-up at index N (include follow-ups 0...N).
    @State private var selectionFollowUpIndex: Int?
    @FocusState private var isFollowUpFocused: Bool

    /// The question currently being streamed — visible in the UI while
    /// waiting for the AI response.
    @State private var pendingFollowUpQuestion: String?
    /// Streaming answer text — updated incrementally as tokens arrive.
    @State private var streamingFollowUpAnswer: String = ""

    /// Scroll-to-bottom anchor for auto-scrolling after follow-up.
    @State private var scrollToBottomID: String?

    /// Controls the Clear History confirmation alert.
    @State private var showClearConfirmation: Bool = false

    /// Inline guidance shown when the user submits without a valid selection.
    @State private var selectionGuidance: String = ""

    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)

    /// Items in chronological order (oldest first) for display.
    /// Internal storage is newest-first; we reverse for the UI.
    private var chronologicalItems: [HistoryRequest] {
        historyManager.items.reversed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            Divider().overlay(accentOrange.opacity(0.15))

            if historyManager.items.isEmpty {
                emptyStateView
            } else {
                historyListView
            }

            Divider().overlay(accentOrange.opacity(0.15))
            followUpInputView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.97, green: 0.96, blue: 0.94))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accentOrange.opacity(0.12), lineWidth: 1)
        )
        .alert("Clear History?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) { clearAllHistory() }
        } message: {
            Text("This will remove all saved requests and their follow-ups.")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accentOrange)
            Text("History")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            if !historyManager.items.isEmpty {
                Button { showClearConfirmation = true } label: {
                    Text("Clear")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.75, green: 0.35, blue: 0.20))
                }
                .buttonStyle(.plain)
                .disabled(isFollowUpLoading)
                .accessibilityLabel("Clear History")
                .padding(.trailing, 8)
            }
            Button { onDismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 28))
                .foregroundStyle(.quaternary)
            Text("No recent requests")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - History List

    private var historyListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let items = chronologicalItems
                    ForEach(Array(items.enumerated()), id: \.element.id) { displayIndex, request in
                        // Use reversed index for block ID stability (internal
                        // storage index). The last display item = items[0] internally.
                        let internalIndex = items.count - 1 - displayIndex
                        HistoryRequestView(
                            request: request,
                            itemIndex: internalIndex,
                            isNewest: displayIndex == items.count - 1,
                            activeSelectionBlockID: activeSelectionBlockID,
                            pendingFollowUpQuestion: displayIndex == items.count - 1 ? pendingFollowUpQuestion : nil,
                            streamingFollowUpAnswer: displayIndex == items.count - 1 ? streamingFollowUpAnswer : "",
                            onSelectionChange: { blockID, text, followUpIndex in
                                handleSelectionChange(blockID: blockID, text: text, sourceRequestId: request.id, followUpIndex: followUpIndex)
                            },
                            onReply: { activateReply() }
                        )
                    }

                    // Invisible anchor for scroll-to-bottom.
                    Color.clear
                        .frame(height: 1)
                        .id("history-bottom-anchor")
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }
            .frame(maxHeight: .infinity)
            .onAppear {
                // Scroll to newest (bottom) when History opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    proxy.scrollTo("history-bottom-anchor", anchor: .bottom)
                }
            }
            .onChange(of: scrollToBottomID) { _, newValue in
                if newValue != nil {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo("history-bottom-anchor", anchor: .bottom)
                    }
                    scrollToBottomID = nil
                }
            }
        }
    }

    // MARK: - Follow-Up Input

    private var followUpInputView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let selection = anchoredResponseSelection {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("Replying to: \"\(selection.text.prefix(80))\(selection.text.count > 80 ? "\u{2026}" : "")\"")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button { clearResponseSelection() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !selectionGuidance.isEmpty {
                Label(selectionGuidance, systemImage: "hand.point.up.left")
                    .foregroundStyle(accentOrange)
                    .font(.system(size: 11, weight: .medium))
            }

            if !followUpError.isEmpty {
                Label(followUpError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.system(size: 11, weight: .medium))
            }

            HStack(spacing: 8) {
                TextField(
                    followUpPlaceholder,
                    text: $followUpText
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(accentOrange.opacity(0.10), lineWidth: 0.5))
                .focused($isFollowUpFocused)
                .onSubmit { submitFollowUp() }
                .disabled(!isFollowUpInputEnabled)

                Button { submitFollowUp() } label: {
                    if isFollowUpLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 32, height: 22)
                    } else {
                        Text("Ask")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(canAskFollowUp ? accentOrange : Color.gray)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canAskFollowUp)
            }
            .onChange(of: replyActivated) { _, activated in
                if activated {
                    isFollowUpFocused = true
                    replyActivated = false
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The input is always enabled (user can compose) unless a follow-up
    /// is currently streaming. Submission validation happens in `submitFollowUp()`.
    private var isFollowUpInputEnabled: Bool {
        !isFollowUpLoading
    }

    /// The Ask button is enabled when the user has typed something and
    /// is not currently loading. Selection validation happens on submit.
    private var canAskFollowUp: Bool {
        !isFollowUpLoading
        && !followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Placeholder text for the follow-up input.
    private var followUpPlaceholder: String {
        if historyManager.items.isEmpty {
            return "No history available"
        }
        if anchoredResponseSelection != nil {
            return "Ask about this selection\u{2026}"
        }
        return "Ask a follow-up\u{2026}"
    }

    // MARK: - Selection Handling (Anchored Follow-Up)

    private func handleSelectionChange(blockID: SelectableBlockID, text: String?, sourceRequestId: UUID, followUpIndex: Int?) {
        if let text, !text.isEmpty {
            let truncated = String(text.prefix(AILimits.maxResponseSelectionCharacters))
            responseSelection = ResponseSelection(blockID: blockID, text: truncated)
            activeSelectionBlockID = blockID
            selectionSourceRequestId = sourceRequestId
            selectionFollowUpIndex = followUpIndex
        } else {
            if activeSelectionBlockID == blockID {
                responseSelection = nil
                activeSelectionBlockID = nil
                selectionSourceRequestId = nil
                selectionFollowUpIndex = nil
            }
        }
    }

    private func activateReply() {
        guard let pending = responseSelection else { return }
        anchoredResponseSelection = pending
        responseSelection = nil
        activeSelectionBlockID = nil
        selectionGuidance = ""
        replyActivated = true
    }

    private func clearResponseSelection() {
        responseSelection = nil
        anchoredResponseSelection = nil
        activeSelectionBlockID = nil
        selectionSourceRequestId = nil
        selectionFollowUpIndex = nil
        replyActivated = false
    }

    private func buildAugmentedQuestion(_ question: String) -> String {
        guard let selection = anchoredResponseSelection else {
            return question
        }
        return "Regarding this specific part of \(selection.sourceDescription): \"\(selection.text)\"\n\n\(question)"
    }

    // MARK: - Clear All History

    /// Resets all local state and delegates to HistoryManager for
    /// in-memory + persistence cleanup. Sends analytics event.
    private func clearAllHistory() {
        // Reset selection state — no references to deleted requests.
        responseSelection = nil
        anchoredResponseSelection = nil
        activeSelectionBlockID = nil
        selectionSourceRequestId = nil
        selectionFollowUpIndex = nil
        replyActivated = false

        // Reset follow-up input state.
        followUpText = ""
        followUpError = ""
        pendingFollowUpQuestion = nil
        streamingFollowUpAnswer = ""

        // Capture count before clearing for analytics.
        let itemCount = historyManager.items.count

        // Delegate to HistoryManager (clears in-memory + deletes file).
        historyManager.clear()

        AnalyticsEventService.send(
            eventType: "history_cleared",
            mode: nil,
            metadata: ["item_count": itemCount]
        )
    }

    // MARK: - Follow-Up Submission

    /// Resolves the HistoryRequest that should provide source context
    /// for the follow-up. Requires an anchored selection — the selection's
    /// source request is the explicit context anchor.
    /// Returns nil if no selection is active or the source request was deleted.
    private func resolveContextRequest() -> HistoryRequest? {
        guard anchoredResponseSelection != nil,
              let sourceId = selectionSourceRequestId else {
            return nil
        }
        return historyManager.items.first(where: { $0.id == sourceId })
    }

    /// Builds the 3-message conversation from a HistoryRequest.
    ///
    /// The first user message always contains the original code with an
    /// explicit label so the model can reference the source code in its
    /// answer. When a custom question was provided, it is included as
    /// additional context.
    ///
    /// Follow-up scope determines which prior follow-ups to include:
    /// - `nil`: include ALL follow-ups (no selection / unanchored follow-up)
    /// - negative or absent follow-ups: include none (main explanation selected)
    /// - `N`: include follow-ups at indices 0...N (follow-up N selected)
    private func buildMessages(from request: HistoryRequest, question: String, throughFollowUpIndex: Int?) -> [AIMessage] {
        var contextParts: [String] = []

        // Always include the original code with an explicit label.
        contextParts.append("The user's original code:\n\(request.originalCode)")

        // Include the personalized query if one was provided.
        if let customQ = request.customQuestion, !customQ.isEmpty {
            contextParts.append("The user's original question about this code: \(customQ)")
        }

        var assistantContent = request.explanation

        // Determine which follow-ups to include.
        let followUpsToInclude: ArraySlice<HistoryFollowUp>
        if let maxIndex = throughFollowUpIndex {
            // Include follow-ups through the specified index.
            let endIndex = min(maxIndex + 1, request.followUps.count)
            followUpsToInclude = request.followUps[0..<endIndex]
        } else {
            // No scope constraint — include all follow-ups.
            followUpsToInclude = request.followUps[0..<request.followUps.count]
        }

        if !followUpsToInclude.isEmpty {
            contextParts.append("Your original explanation:\n\(request.explanation)")
            for fu in followUpsToInclude {
                contextParts.append("Follow-up question: \(fu.question)")
                contextParts.append("Follow-up answer: \(fu.answer)")
            }
            assistantContent = followUpsToInclude.last?.answer ?? request.explanation
        }

        let sourceContent = contextParts.joined(separator: "\n\n")

        return [
            AIMessage(role: .user, content: sourceContent),
            AIMessage(role: .assistant, content: assistantContent),
            AIMessage(role: .user, content: question),
        ]
    }

    private func submitFollowUp() {
        let rawQuestion = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawQuestion.isEmpty else { return }
        // Selection is required — no implicit target.
        // Show guidance and preserve the user's question if missing.
        guard anchoredResponseSelection != nil else {
            selectionGuidance = "Select text above, then click Reply ↩ to ask about it."
            return
        }
        guard let contextRequest = resolveContextRequest() else {
            selectionGuidance = "The selected request is no longer available."
            return
        }
        guard let provider = aiProviderClosure() else {
            followUpError = "AI provider not available"
            return
        }
        guard let tracker = usageTrackerClosure() else {
            followUpError = "Usage tracker not available"
            return
        }

        guard tracker.tryConsumeRequest() else {
            followUpError = tracker.quotaExhaustedMessage
            return
        }

        let question = buildAugmentedQuestion(rawQuestion)
        let capturedRawQuestion = rawQuestion
        let capturedRequestId = contextRequest.id

        // Follow-up scope from the anchored selection (always present at this point).
        // nil selectionFollowUpIndex means main explanation → -1 to exclude all follow-ups.
        // N means follow-up at index N → include follow-ups 0...N.
        let followUpScope = selectionFollowUpIndex ?? -1

        // Show the question immediately in the UI while streaming.
        pendingFollowUpQuestion = capturedRawQuestion
        streamingFollowUpAnswer = ""
        followUpText = ""
        isFollowUpLoading = true
        followUpError = ""
        selectionGuidance = ""

        // Scroll to bottom so the user sees the streaming answer.
        scrollToBottomID = UUID().uuidString

        Task {
            let messages = buildMessages(from: contextRequest, question: question, throughFollowUpIndex: followUpScope)
            let followUpMode = "\(contextRequest.mode)_followup"

            // Use the canonical follow-up system prompt from ExplanationHUDViewModel.
            let systemPrompt = ExplanationHUDViewModel.historyFollowUpSystemPrompt

            do {
                let stream = try await provider.streamChat(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    mode: followUpMode,
                    contextTier: nil,
                    explanationProfile: contextRequest.explanationProfile,
                    language: contextRequest.language
                )

                var answer = ""
                for try await token in stream {
                    if Task.isCancelled { break }
                    answer += token
                    streamingFollowUpAnswer = answer
                }

                if !Task.isCancelled && !answer.isEmpty {
                    historyManager.recordFollowUp(
                        requestId: capturedRequestId,
                        question: capturedRawQuestion,
                        answer: answer
                    )
                    // Clear streaming state — the persisted follow-up is now
                    // rendered by HistoryRequestView's followUpSection.
                    pendingFollowUpQuestion = nil
                    streamingFollowUpAnswer = ""
                    clearResponseSelection()

                    // Analytics: selection_source from the anchored block source,
                    // followup_depth from the follow-up index (-1 = main explanation).
                    let selectionSource: String = {
                        guard let sel = self.anchoredResponseSelection else { return "unknown" }
                        switch sel.blockID.source {
                        case .explanation: return "explanation"
                        case .followUpQuestion: return "followup_question"
                        case .followUpAnswer: return "followup_answer"
                        }
                    }()
                    AnalyticsEventService.send(
                        eventType: "history_followup",
                        mode: followUpMode,
                        metadata: [
                            "selection_source": selectionSource,
                            "followup_depth": followUpScope < 0 ? 0 : followUpScope + 1,
                        ]
                    )
                }

                isFollowUpLoading = false
            } catch is CancellationError {
                pendingFollowUpQuestion = nil
                streamingFollowUpAnswer = ""
                isFollowUpLoading = false
            } catch {
                if !Task.isCancelled {
                    followUpError = error.localizedDescription
                    pendingFollowUpQuestion = nil
                    streamingFollowUpAnswer = ""
                    isFollowUpLoading = false
                }
            }
        }
    }
}

// MARK: - History Request View

private struct HistoryRequestView: View {
    let request: HistoryRequest
    let itemIndex: Int
    let isNewest: Bool
    let activeSelectionBlockID: SelectableBlockID?
    let pendingFollowUpQuestion: String?
    let streamingFollowUpAnswer: String
    /// Selection callback: (blockID, selectedText, followUpIndex).
    /// `followUpIndex` is nil for main explanation, or the follow-up array index.
    let onSelectionChange: (SelectableBlockID, String?, Int?) -> Void
    let onReply: () -> Void

    @State private var isCodeExpanded: Bool = false

    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)

    /// Base offset for block IDs in this request, ensuring global uniqueness.
    /// Each request gets a 1000-wide ID range.
    private var blockIDBase: Int { itemIndex * 1000 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Request header
            requestHeader
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Divider()
                .overlay(accentOrange.opacity(0.10))
                .padding(.horizontal, 12)

            // Request content
            VStack(alignment: .leading, spacing: 8) {
                // Personalized query (only if present)
                if let query = request.customQuestion, !query.isEmpty {
                    personalizedQuerySection(query)
                }

                // Collapsible code
                codeSection

                // Explanation
                explanationSection

                // Persisted follow-ups
                followUpSection

                // Streaming follow-up (only on newest request)
                if let question = pendingFollowUpQuestion {
                    streamingFollowUpSection(question: question)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.white.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accentOrange.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
    }

    // MARK: - Request Header

    private var requestHeader: some View {
        HStack(spacing: 6) {
            Text(modeLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(accentOrange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(accentOrange.opacity(0.12)))

            if let fileName = request.fileName {
                Text(fileName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(timeAgo(request.createdAt))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Personalized Query

    @ViewBuilder
    private func personalizedQuerySection(_ query: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Question")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.3)

            Text("\u{201C}\(query)\u{201D}")
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.8))
                .italic()
        }
        .padding(.bottom, 2)
    }

    // MARK: - Code Section

    @ViewBuilder
    private var codeSection: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isCodeExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCodeExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Text(isCodeExpanded ? "Hide Code" : "Code")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)

        if isCodeExpanded {
            SelectableTextView(
                attributedString: codeAttributedString(request.originalCode),
                blockID: SelectableBlockID(source: .explanation, index: blockIDBase + 200),
                activeSelectionBlockID: activeSelectionBlockID,
                onSelectionChange: { blockID, text in
                    onSelectionChange(blockID, text, nil)
                },
                onReply: { onReply() }
            )
            .padding(10)
            .background(Color(red: 0.95, green: 0.94, blue: 0.93))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Explanation Section

    @ViewBuilder
    private var explanationSection: some View {
        ForEach(ExplanationTagParser.blocks(from: request.explanation)) { block in
            renderBlock(block, source: .explanation, idOffset: blockIDBase, followUpIndex: nil)
        }
    }

    // MARK: - Follow-Up Section (persisted)

    @ViewBuilder
    private var followUpSection: some View {
        if !request.followUps.isEmpty {
            ForEach(Array(request.followUps.enumerated()), id: \.element.id) { fuIndex, followUp in
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                        .overlay(accentOrange.opacity(0.08))

                    // Question — selectable for Reply ↩
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrowshape.turn.up.right")
                            .font(.system(size: 9))
                            .foregroundStyle(accentOrange.opacity(0.6))
                            .padding(.top, 2)
                        SelectableTextView(
                            attributedString: followUpQuestionAttributedString(followUp.question),
                            blockID: SelectableBlockID(source: .followUpQuestion, index: blockIDBase + 300 + fuIndex),
                            activeSelectionBlockID: activeSelectionBlockID,
                            onSelectionChange: { blockID, text in
                                onSelectionChange(blockID, text, fuIndex)
                            },
                            onReply: { onReply() }
                        )
                    }

                    // Answer
                    ForEach(ExplanationTagParser.blocks(from: followUp.answer)) { block in
                        renderBlock(block, source: .followUpAnswer, idOffset: blockIDBase + 500 + fuIndex * 50, followUpIndex: fuIndex)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    /// Creates a styled AttributedString for a follow-up question.
    private func followUpQuestionAttributedString(_ question: String) -> AttributedString {
        var str = AttributedString(question)
        str.font = .system(size: 12, weight: .medium)
        return str
    }

    /// Creates a styled AttributedString for original code.
    private func codeAttributedString(_ code: String) -> AttributedString {
        var str = AttributedString(code)
        str.font = .system(size: 11).monospaced()
        return str
    }

    // MARK: - Streaming Follow-Up Section

    @ViewBuilder
    private func streamingFollowUpSection(question: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .overlay(accentOrange.opacity(0.08))

            // Question (already submitted)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrowshape.turn.up.right")
                    .font(.system(size: 9))
                    .foregroundStyle(accentOrange.opacity(0.6))
                    .padding(.top, 2)
                Text(question)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }

            // Streaming answer
            if streamingFollowUpAnswer.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Thinking...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            } else {
                ForEach(ExplanationTagParser.blocks(from: streamingFollowUpAnswer)) { block in
                    renderStreamingBlock(block)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Block Rendering

    @ViewBuilder
    private func renderBlock(_ block: ContentBlock, source: SelectableBlockSource, idOffset: Int, followUpIndex: Int?) -> some View {
        switch block {
        case .inlineRun(let id, let segments):
            SelectableTextView(
                attributedString: ExplanationTagParser.attributedString(from: segments),
                blockID: SelectableBlockID(source: source, index: id + idOffset),
                activeSelectionBlockID: activeSelectionBlockID,
                onSelectionChange: { blockID, text in
                    onSelectionChange(blockID, text, followUpIndex)
                },
                onReply: { onReply() }
            )
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

    /// Renders streaming blocks without selection support (the answer is
    /// still arriving and will be replaced by the persisted version).
    @ViewBuilder
    private func renderStreamingBlock(_ block: ContentBlock) -> some View {
        switch block {
        case .inlineRun(_, let segments):
            Text(ExplanationTagParser.attributedString(from: segments))
                .font(.system(size: 12))
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

    // MARK: - Helpers

    private var modeLabel: String {
        switch request.mode {
        case "session": return "Session"
        case "selection": return "Selection"
        case "screenshot": return "Screenshot"
        default: return request.mode.capitalized
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }
}

// MARK: - Keyable Panel

/// NSPanel subclass that allows becoming the key window.
///
/// A plain NSPanel with `.nonactivatingPanel` returns `false` from `canBecomeKey`,
/// which prevents TextField keyboard input from being received. This subclass
/// overrides `canBecomeKey` to return `true` so that the follow-up text field
/// works while still preserving non-activating behavior.
private final class HistoryKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
