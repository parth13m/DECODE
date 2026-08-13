// FloatingHistoryHUD.swift — Decode Presentation
//
// The History HUD: a scrollable list of the user's 10 most recent
// explanation requests with their follow-up conversations. Supports
// code collapse/expand, text selection with Anchored Reply, and
// follow-up from the most recent request.
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
        positionPanel(panel)
        panel.orderFrontRegardless()

        AnalyticsEventService.send(eventType: "history_opened", mode: nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Panel Construction

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
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
    @FocusState private var isFollowUpFocused: Bool

    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            Divider().overlay(Color(red: 0.91, green: 0.90, blue: 0.88))

            if historyManager.items.isEmpty {
                emptyStateView
            } else {
                historyListView
            }

            Divider().overlay(Color(red: 0.91, green: 0.90, blue: 0.88))
            followUpInputView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.99, green: 0.98, blue: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
        )
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
            Button { onDismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(historyManager.items.enumerated()), id: \.element.id) { itemIndex, request in
                    HistoryRequestView(
                        request: request,
                        itemIndex: itemIndex,
                        activeSelectionBlockID: activeSelectionBlockID,
                        onSelectionChange: { blockID, text in
                            handleSelectionChange(blockID: blockID, text: text)
                        },
                        onReply: { activateReply() }
                    )

                    if itemIndex < historyManager.items.count - 1 {
                        Divider()
                            .overlay(Color(red: 0.91, green: 0.90, blue: 0.88))
                            .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity)
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

            if !followUpError.isEmpty {
                Label(followUpError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.system(size: 11, weight: .medium))
            }

            HStack(spacing: 8) {
                TextField(
                    historyManager.items.isEmpty
                        ? "No history available"
                        : (anchoredResponseSelection != nil
                            ? "Ask about this selection..."
                            : "Ask a follow-up question..."),
                    text: $followUpText
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(red: 0.95, green: 0.94, blue: 0.93))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .focused($isFollowUpFocused)
                .onSubmit { submitFollowUp() }
                .disabled(isFollowUpLoading || historyManager.items.isEmpty)

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

    private var canAskFollowUp: Bool {
        !isFollowUpLoading
        && !historyManager.items.isEmpty
        && !followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Selection Handling (Anchored Follow-Up)

    private func handleSelectionChange(blockID: SelectableBlockID, text: String?) {
        if let text, !text.isEmpty {
            let truncated = String(text.prefix(AILimits.maxResponseSelectionCharacters))
            responseSelection = ResponseSelection(blockID: blockID, text: truncated)
            activeSelectionBlockID = blockID
        } else {
            if activeSelectionBlockID == blockID {
                responseSelection = nil
                activeSelectionBlockID = nil
            }
        }
    }

    private func activateReply() {
        guard let pending = responseSelection else { return }
        anchoredResponseSelection = pending
        responseSelection = nil
        activeSelectionBlockID = nil
        followUpText = ""
        replyActivated = true
    }

    private func clearResponseSelection() {
        responseSelection = nil
        anchoredResponseSelection = nil
        activeSelectionBlockID = nil
        replyActivated = false
    }

    private func buildAugmentedQuestion(_ question: String) -> String {
        guard let selection = anchoredResponseSelection else {
            return question
        }
        let source = selection.isFollowUp
            ? "your follow-up answer"
            : "your previous response"
        return "Regarding this specific part of \(source): \"\(selection.text)\"\n\n\(question)"
    }

    // MARK: - Follow-Up Submission

    private func submitFollowUp() {
        let rawQuestion = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawQuestion.isEmpty else { return }
        guard let activeRequest = historyManager.activeRequest else { return }
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
        let capturedRequestId = activeRequest.id

        isFollowUpLoading = true
        followUpError = ""

        Task {
            // Build conversation from historical context using the legacy
            // 3-message pattern. This is the correct approach for History
            // follow-ups because the pipeline's ConversationState is transient
            // and not persisted — only the user-visible transcript is available.
            var sourceContent = activeRequest.originalCode
            var assistantContent = activeRequest.explanation

            // If there are prior follow-ups, build a multi-turn conversation.
            // The legacy path uses a 3-message window, but we provide the full
            // context by appending prior Q&A to the assistant content.
            if !activeRequest.followUps.isEmpty {
                var contextParts: [String] = []
                contextParts.append("Original code:\n\(activeRequest.originalCode)")
                contextParts.append("Original explanation:\n\(activeRequest.explanation)")
                for fu in activeRequest.followUps {
                    contextParts.append("Follow-up question: \(fu.question)")
                    contextParts.append("Follow-up answer: \(fu.answer)")
                }
                sourceContent = contextParts.joined(separator: "\n\n")
                assistantContent = activeRequest.followUps.last?.answer ?? activeRequest.explanation
            }

            let messages: [AIMessage] = [
                AIMessage(role: .user, content: sourceContent),
                AIMessage(role: .assistant, content: assistantContent),
                AIMessage(role: .user, content: question),
            ]

            let followUpMode = "\(activeRequest.mode)_followup"

            // Use the canonical follow-up system prompt from ExplanationHUDViewModel.
            let systemPrompt = ExplanationHUDViewModel.historyFollowUpSystemPrompt

            do {
                let stream = try await provider.streamChat(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    mode: followUpMode,
                    contextTier: nil,
                    explanationProfile: activeRequest.explanationProfile,
                    language: activeRequest.language
                )

                var answer = ""
                for try await token in stream {
                    if Task.isCancelled { break }
                    answer += token
                }

                if !Task.isCancelled && !answer.isEmpty {
                    historyManager.recordFollowUp(
                        requestId: capturedRequestId,
                        question: capturedRawQuestion,
                        answer: answer
                    )
                    followUpText = ""
                    clearResponseSelection()

                    AnalyticsEventService.send(
                        eventType: "history_followup",
                        mode: activeRequest.mode
                    )
                }

                isFollowUpLoading = false
            } catch is CancellationError {
                isFollowUpLoading = false
            } catch {
                if !Task.isCancelled {
                    followUpError = error.localizedDescription
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
    let activeSelectionBlockID: SelectableBlockID?
    let onSelectionChange: (SelectableBlockID, String?) -> Void
    let onReply: () -> Void

    @State private var isCodeExpanded: Bool = false

    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)

    /// Base offset for block IDs in this request, ensuring global uniqueness.
    /// Each request gets a 1000-wide ID range.
    private var blockIDBase: Int { itemIndex * 1000 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Request metadata
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

            // Collapsible code
            codeSection

            // Explanation
            explanationSection

            // Follow-ups
            followUpSection
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            ScrollView(.horizontal, showsIndicators: false) {
                Text(request.originalCode)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color(red: 0.95, green: 0.94, blue: 0.93))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Explanation Section

    @ViewBuilder
    private var explanationSection: some View {
        ForEach(ExplanationTagParser.blocks(from: request.explanation)) { block in
            renderBlock(block, source: .explanation, idOffset: blockIDBase)
        }
    }

    // MARK: - Follow-Up Section

    @ViewBuilder
    private var followUpSection: some View {
        if !request.followUps.isEmpty {
            ForEach(Array(request.followUps.enumerated()), id: \.element.id) { fuIndex, followUp in
                VStack(alignment: .leading, spacing: 4) {
                    // Question
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrowshape.turn.up.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        Text(followUp.question)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                    }

                    // Answer
                    ForEach(ExplanationTagParser.blocks(from: followUp.answer)) { block in
                        renderBlock(block, source: .followUpAnswer, idOffset: blockIDBase + 500 + fuIndex * 50)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    // MARK: - Block Rendering

    @ViewBuilder
    private func renderBlock(_ block: ContentBlock, source: SelectableBlockSource, idOffset: Int) -> some View {
        switch block {
        case .inlineRun(let id, let segments):
            SelectableTextView(
                attributedString: ExplanationTagParser.attributedString(from: segments),
                blockID: SelectableBlockID(source: source, index: id + idOffset),
                activeSelectionBlockID: activeSelectionBlockID,
                onSelectionChange: { blockID, text in
                    onSelectionChange(blockID, text)
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
