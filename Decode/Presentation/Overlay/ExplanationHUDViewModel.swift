import AppKit
import ConsumerRuntime
import Foundation

/// The display state of the floating explanation HUD.
enum HUDDisplayState: Sendable {
    /// HUD is hidden, no content.
    case idle
    /// AI request in progress, no tokens received yet.
    case loading
    /// Tokens are streaming in. The `explanationText` property accumulates content.
    case streaming
    /// Streaming completed successfully.
    case complete
    /// An error occurred. The `errorMessage` property contains the description.
    case error
}

/// ViewModel for the floating explanation HUD.
///
/// Manages the HUD's content state: text accumulation during streaming,
/// loading indicators, error display, and dismiss behavior. Decoupled from
/// window lifecycle — ``FloatingExplanationHUD`` handles NSPanel management.
///
/// Also manages V1 follow-up questions: stores the context from the original
/// request so the user can ask a single follow-up without the coordinator.
@Observable
@MainActor
final class ExplanationHUDViewModel {

    // MARK: - State

    /// Current display state of the HUD.
    private(set) var displayState: HUDDisplayState = .idle

    /// The accumulated explanation text. Grows incrementally during streaming.
    private(set) var explanationText: String = ""

    /// Error message to display, if any.
    private(set) var errorMessage: String = ""

    /// The name of the application the text was captured from.
    private(set) var sourceAppName: String?

    /// The mode that produced this explanation ("selection", "session", "screenshot").
    private(set) var modeName: String?

    /// The resolved session file name (Session Mode only).
    private(set) var sessionFileName: String?

    /// The explanation profile ("general" or "dsa").
    private(set) var explanationProfile: String?

    /// Whether the HUD should be visible.
    var isVisible: Bool { displayState != .idle }

    /// Whether the HUD is currently receiving streamed content.
    var isStreaming: Bool { displayState == .loading || displayState == .streaming }

    // MARK: - Follow-up State

    /// The latest follow-up answer, rendered separately from the explanation.
    private(set) var followUpAnswer: String = ""

    /// Whether a follow-up request is in flight.
    private(set) var isFollowUpLoading: Bool = false

    /// Error from the most recent follow-up attempt.
    private(set) var followUpError: String = ""

    /// User's follow-up question text (bound to TextField).
    var followUpText: String = ""

    /// Whether follow-up is available (explanation complete + provider exists).
    var canAskFollowUp: Bool {
        displayState == .complete && !isFollowUpLoading && followUpContext != nil
    }

    // MARK: - Follow-up Context (set by showStream, used by askFollowUp)

    /// Captured context from the original request, used to build follow-up messages.
    private var followUpContext: FollowUpContext?

    struct FollowUpContext {
        let sourceContent: String
        let systemPrompt: String
        let mode: String?
        let aiProvider: any AIProviderProtocol
        let usageTracker: AIUsageTracker

        /// The raw captured code snippet, independent of the user message text.
        /// Used by the improvement flow to send the original code to the AI.
        let originalCode: String?

        /// Explanation profile used for the original explanation. Passed through
        /// to improvement requests so they participate in profile analytics.
        let explanationProfile: String?

        /// Detected language of the code. Passed through to improvement requests
        /// so they participate in language analytics.
        let language: String?

        /// Session context from the original explanation, reused by Session
        /// Improve so it operates on the same tier/outline/entity data.
        /// `nil` for Selection and Screenshot modes.
        let sessionContext: SessionContext?

        // MARK: - Pipeline Follow-Up State

        /// Pipeline query service for follow-up via the understanding pipeline.
        /// `nil` when the initial explanation used the legacy path.
        let pipelineQueryService: PipelineQueryService?

        /// ConversationState from the pipeline's Understanding.
        /// Used by follow-up and improve to maintain pipeline conversation continuity.
        /// `nil` when the initial explanation used the legacy path.
        var pipelineConversationState: ConversationState?

        /// File path for the session file. Used by pipeline follow-up to re-query.
        let pipelineFilePath: String?

        /// Entity name resolved during the initial pipeline query.
        let pipelineEntityName: String?
    }

    // MARK: - Follow-up Prompt

    /// Dedicated system prompt for follow-up questions. Unlike the explanation
    /// prompt, this instructs the model to answer concisely without regenerating
    /// Purpose/Flow/Example/Important Lines/Summary sections.
    private static let followUpSystemPrompt = """
        You are Decode, a code explanation assistant. The user already received \
        a full explanation of their code. Now they are asking a follow-up question.

        LENGTH:
        - Default: 3–6 sentences. No more.
        - Go longer ONLY if the user explicitly asks to "explain in detail", \
        "walk through", "compare", "give examples", or asks "why" or "how".

        RULES:
        - Answer ONLY the question that was asked. Nothing else.
        - Do NOT provide optimizations, alternative implementations, refactors, \
        best practices, or suggestions unless the user explicitly asks for them.
        - If a short example helps answer the question, include one. Keep it minimal.
        - Reference the original code or explanation when it helps clarify.
        - Do NOT output Purpose, Flow, Example, Important Lines, or Summary sections.
        - Do NOT use **bold section labels** to structure your response.

        FORMATTING:
        - Use <hl>text</hl> sparingly for the most important term, variable, or \
        function name when it improves readability.
        - Use <critical>text</critical> only for bugs or dangerous patterns.
        - Use inline code backticks for short code references.
        - Do NOT use <flow>, <tldr>, <tip>, <note>, or <analogy> tags.
        - Do NOT use markdown headings (## or ###).
        """

    // MARK: - Improvement State

    /// The raw streamed text from the improvement AI response.
    private(set) var improvementRawText: String = ""

    /// Parsed summary explaining what changed and why.
    private(set) var improvementSummary: String = ""

    /// Parsed improved code, ready to copy.
    private(set) var improvedCode: String = ""

    /// Whether an improvement request is in flight.
    private(set) var isImprovementLoading: Bool = false

    /// Error from the most recent improvement attempt.
    private(set) var improvementError: String = ""

    /// Whether the "Improve Code" button should be enabled.
    ///
    /// Available when: explanation is complete, mode is not screenshot,
    /// original code exists in context, and no improvement is in progress.
    var canRequestImprovement: Bool {
        displayState == .complete
            && !isImprovementLoading
            && improvedCode.isEmpty
            && improvementSummary.isEmpty
            && followUpContext?.originalCode != nil
            && followUpContext?.mode != "screenshot"
    }

    /// Whether an improvement result is available for display.
    var hasImprovementResult: Bool {
        !improvedCode.isEmpty || !improvementSummary.isEmpty || isImprovementLoading || !improvementError.isEmpty
    }

    /// The original captured code, exposed for the improvement UI comparison view.
    var followUpContextOriginalCode: String {
        followUpContext?.originalCode ?? ""
    }

    // MARK: - Replacement State

    /// Confirmation message shown after a successful replacement.
    private(set) var replacementConfirmation: String = ""

    /// Error message from a failed replacement attempt.
    private(set) var replacementError: String = ""

    /// Whether a replacement is currently in progress.
    private(set) var isReplacing: Bool = false

    /// Whether the Replace button should be enabled.
    var canReplace: Bool {
        !improvedCode.isEmpty && !isImprovementLoading && replacementConfirmation.isEmpty && !isReplacing
    }

    // MARK: - Active Stream

    /// The currently active streaming task. Cancelled on dismiss or new stream.
    private var activeStreamTask: Task<Void, Never>?

    /// The currently active follow-up task.
    private var followUpTask: Task<Void, Never>?

    /// The currently active improvement task.
    private var improvementTask: Task<Void, Never>?

    /// Service for replacing selected text in the editor via clipboard + paste.
    private let textReplacementService = TextReplacementService()

    // MARK: - Actions

    /// Show the HUD in loading state before the AI request starts.
    ///
    /// Resets state and enters `.loading` so the user sees immediate feedback.
    /// When the stream is ready, ``showStream(_:sourceApp:followUpContext:)``
    /// transitions to `.streaming`.
    func showLoading(sourceApp: String?, mode: String? = nil, sessionFile: String? = nil, explanationProfile: String? = nil) {
        activeStreamTask?.cancel()
        followUpTask?.cancel()
        improvementTask?.cancel()

        explanationText = ""
        errorMessage = ""
        sourceAppName = sourceApp
        modeName = mode
        sessionFileName = sessionFile
        self.explanationProfile = explanationProfile
        displayState = .loading

        followUpAnswer = ""
        followUpError = ""
        followUpText = ""
        isFollowUpLoading = false
        followUpContext = nil
        resetImprovementState()
    }

    /// Begin streaming an AI explanation into the HUD.
    ///
    /// Cancels any in-flight stream, resets state, and consumes tokens from
    /// the provided `AsyncThrowingStream`. Each token is appended to
    /// `explanationText` so the UI updates incrementally.
    ///
    /// - Parameters:
    ///   - stream: The token stream from the AI provider.
    ///   - sourceApp: The name of the app the text was captured from.
    ///   - context: Optional follow-up context for post-explanation questions.
    ///   - onComplete: Called with the full explanation text when streaming
    ///     completes (including partial completion on error). Not called on
    ///     cancellation. Runs on MainActor.
    func showStream(
        _ stream: AsyncThrowingStream<String, Error>,
        sourceApp: String?,
        followUpContext context: FollowUpContext? = nil,
        onComplete: (@MainActor (String) -> Void)? = nil
    ) {
        // Cancel any previous stream, follow-up, or improvement.
        activeStreamTask?.cancel()
        followUpTask?.cancel()
        improvementTask?.cancel()

        // Reset state for new explanation.
        explanationText = ""
        errorMessage = ""
        sourceAppName = sourceApp
        displayState = .loading

        // Reset follow-up state.
        followUpAnswer = ""
        followUpError = ""
        followUpText = ""
        isFollowUpLoading = false
        followUpContext = context

        // Reset improvement state.
        resetImprovementState()

        activeStreamTask = Task {
            // DIAG: HUD ViewModel streaming diagnostics
            #if DEBUG
            let diagStreamStart = CFAbsoluteTimeGetCurrent()
            var diagFirstTokenTime: CFAbsoluteTime?
            var diagTokenCount = 0
            var diagUIUpdateCount = 0
            #endif

            do {
                for try await token in stream {
                    if Task.isCancelled { break }

                    #if DEBUG
                    diagTokenCount += 1
                    if diagFirstTokenTime == nil {
                        diagFirstTokenTime = CFAbsoluteTimeGetCurrent()
                        let firstMs = (diagFirstTokenTime! - diagStreamStart) * 1000
                        print("[DIAG_HUD] first_token_ms=\(String(format: "%.0f", firstMs))")
                    }
                    #endif

                    if displayState == .loading {
                        displayState = .streaming
                    }
                    explanationText += token

                    #if DEBUG
                    diagUIUpdateCount += 1
                    #endif
                }

                if !Task.isCancelled {
                    #if DEBUG
                    let totalMs = (CFAbsoluteTimeGetCurrent() - diagStreamStart) * 1000
                    print("[DIAG_HUD] complete total_ms=\(String(format: "%.0f", totalMs)) tokens=\(diagTokenCount) ui_updates=\(diagUIUpdateCount) final_length=\(explanationText.count)")
                    #endif
                    displayState = .complete
                    onComplete?(explanationText)
                }
            } catch is CancellationError {
                // Stream was cancelled (dismiss or new stream). No error state.
            } catch {
                if !Task.isCancelled {
                    if explanationText.isEmpty {
                        // No content received — show full error state.
                        errorMessage = error.localizedDescription
                        displayState = .error
                    } else {
                        // Partial content received — mark complete so partial
                        // content stays visible, and append the error as a note.
                        errorMessage = error.localizedDescription
                        displayState = .complete
                        onComplete?(explanationText)
                    }
                }
            }
        }
    }

    /// Ask a follow-up question using the context from the original request.
    ///
    /// Attempts the pipeline path first when pipeline state is available
    /// (ConversationState round-trip through FollowUpReasoningEngine).
    /// Falls back to the legacy 3-message conversation path on pipeline
    /// failure or when pipeline state is absent.
    func askFollowUp() {
        let question = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard let ctx = followUpContext else { return }

        // Check quota.
        guard ctx.usageTracker.tryConsumeRequest() else {
            followUpError = ctx.usageTracker.quotaExhaustedMessage
            return
        }

        isFollowUpLoading = true
        followUpAnswer = ""
        followUpError = ""

        followUpTask = Task {
            // Attempt pipeline follow-up when state is available.
            if let service = ctx.pipelineQueryService,
               let conversationState = ctx.pipelineConversationState,
               let filePath = ctx.pipelineFilePath,
               let entityName = ctx.pipelineEntityName {

                let result = await Task.detached {
                    await service.queryFollowUp(
                        filePath: filePath,
                        entityName: entityName,
                        question: question,
                        conversationState: conversationState
                    )
                }.value

                if case .success(let understanding) = result {
                    if !Task.isCancelled {
                        followUpAnswer = understanding.content
                        // Update conversation state for subsequent follow-ups.
                        followUpContext?.pipelineConversationState = understanding.conversationState
                        isFollowUpLoading = false
                        followUpText = ""
                    }
                    return
                }

                #if DEBUG
                print("[DEBUG HUD] pipeline follow-up failed, falling back to legacy path: \(result)")
                #endif
                // Fall through to legacy path.
            }

            // Legacy path: 3-message conversation via streamChat.
            await askFollowUpLegacy(question: question, ctx: ctx)
        }
    }

    /// Legacy follow-up path: builds a 3-message conversation and streams the response.
    private func askFollowUpLegacy(question: String, ctx: FollowUpContext) async {
        let messages: [AIMessage] = [
            AIMessage(role: .user, content: ctx.sourceContent),
            AIMessage(role: .assistant, content: explanationText),
            AIMessage(role: .user, content: question),
        ]

        // Combine the original session context with follow-up formatting rules
        // so the model retains file structure knowledge while answering concisely.
        let combinedSystemPrompt = ctx.systemPrompt + "\n\n---\n\n" + Self.followUpSystemPrompt

        // Compound follow-up mode for analytics (e.g. "selection" → "selection_followup").
        let followUpMode: String? = if let mode = ctx.mode {
            "\(mode)_followup"
        } else {
            "followup"
        }

        do {
            let stream = try await ctx.aiProvider.streamChat(
                messages: messages,
                systemPrompt: combinedSystemPrompt,
                mode: followUpMode,
                contextTier: nil,
                explanationProfile: ctx.explanationProfile,
                language: ctx.language
            )

            for try await token in stream {
                if Task.isCancelled { break }
                followUpAnswer += token
            }

            if !Task.isCancelled {
                isFollowUpLoading = false
                followUpText = ""
            }
        } catch is CancellationError {
            isFollowUpLoading = false
        } catch {
            if !Task.isCancelled {
                followUpError = error.localizedDescription
                isFollowUpLoading = false
            }
        }
    }

    // MARK: - Improvement Actions

    /// Request an AI-generated improvement of the original code.
    ///
    /// Uses the original code from ``FollowUpContext`` and the explanation
    /// as context. Streams the response and parses it into summary + code.
    func requestImprovement() {
        guard let ctx = followUpContext,
              let originalCode = ctx.originalCode
        else { return }

        // Check quota.
        guard ctx.usageTracker.tryConsumeRequest() else {
            improvementError = ctx.usageTracker.quotaExhaustedMessage
            return
        }

        improvementTask?.cancel()

        isImprovementLoading = true
        improvementRawText = ""
        improvementSummary = ""
        improvedCode = ""
        improvementError = ""

        improvementTask = Task {
            // Pipeline path: attempt when pipeline state is available.
            if let service = ctx.pipelineQueryService,
               let filePath = ctx.pipelineFilePath,
               let entityName = ctx.pipelineEntityName {
                let result = await Task.detached {
                    await service.query(
                        filePath: filePath,
                        entityName: entityName,
                        purpose: "improve"
                    )
                }.value

                if case .success(let understanding) = result {
                    if !Task.isCancelled {
                        let parsed = ImprovementService.parseResponse(understanding.content)
                        improvementSummary = parsed.summary
                        improvedCode = parsed.improvedCode
                        isImprovementLoading = false

                        let mode = ImprovementService.improvementMode(from: ctx.mode)

                        #if DEBUG
                        print("[DIAG_IMPROVE] pipeline complete summary_len=\(parsed.summary.count) code_len=\(parsed.improvedCode.count)")
                        #endif

                        if parsed.improvedCode.isEmpty {
                            AnalyticsEventService.send(
                                eventType: "improve_no_change",
                                mode: mode,
                                metadata: ["summary_length": parsed.summary.count]
                            )
                        }
                    }
                    return
                }
                // Fall through to legacy path.
            }

            await requestImprovementLegacy(originalCode: originalCode, ctx: ctx)
        }
    }

    /// Legacy improvement path: direct AI provider call with streaming response.
    ///
    /// Used when the pipeline is unavailable or fails. Preserves the original
    /// Selection and Session mode improvement flows exactly.
    private func requestImprovementLegacy(originalCode: String, ctx: FollowUpContext) async {
        let messages: [AIMessage] = [
            AIMessage(role: .user, content: originalCode),
        ]

        let mode = ImprovementService.improvementMode(from: ctx.mode)

        // Use context-aware prompt for Session Improve, generic for Selection.
        let improveSystemPrompt: String
        let contextTier: String?
        if let sessionCtx = ctx.sessionContext {
            improveSystemPrompt = ImprovementService.contextAwareSystemPrompt(context: sessionCtx)
            contextTier = sessionCtx.contextTier
        } else {
            improveSystemPrompt = ImprovementService.systemPrompt
            contextTier = nil
        }

        do {
            let stream = try await ctx.aiProvider.streamChat(
                messages: messages,
                systemPrompt: improveSystemPrompt,
                mode: mode,
                contextTier: contextTier,
                explanationProfile: ctx.explanationProfile,
                language: ctx.language
            )

            for try await token in stream {
                if Task.isCancelled { break }
                improvementRawText += token
            }

            if !Task.isCancelled {
                let result = ImprovementService.parseResponse(improvementRawText)
                improvementSummary = result.summary
                improvedCode = result.improvedCode
                isImprovementLoading = false

                #if DEBUG
                print("[DIAG_IMPROVE] complete summary_len=\(result.summary.count) code_len=\(result.improvedCode.count)")
                #endif

                // Report no-change outcome when AI found nothing to improve.
                if result.improvedCode.isEmpty {
                    AnalyticsEventService.send(
                        eventType: "improve_no_change",
                        mode: mode,
                        metadata: ["summary_length": result.summary.count]
                    )
                }
            }
        } catch is CancellationError {
            isImprovementLoading = false
        } catch {
            if !Task.isCancelled {
                improvementError = error.localizedDescription
                isImprovementLoading = false
            }
        }
    }

    /// Copy the improved code to the system clipboard.
    func copyImprovedCode() {
        guard !improvedCode.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(improvedCode, forType: .string)

        let mode = followUpContext.flatMap { ImprovementService.improvementMode(from: $0.mode) }
        AnalyticsEventService.send(
            eventType: "improve_copy",
            mode: mode,
            metadata: improvementMetadata()
        )

        #if DEBUG
        print("[DIAG_IMPROVE] copied \(improvedCode.count) chars to clipboard")
        #endif
    }

    /// Cancel and hide the improvement section.
    func cancelImprovement() {
        // Only report dismiss if improvement completed (not cancelled during loading).
        let hadImprovedCode = !improvedCode.isEmpty || !improvementSummary.isEmpty
        if hadImprovedCode {
            let mode = followUpContext.flatMap { ImprovementService.improvementMode(from: $0.mode) }
            AnalyticsEventService.send(
                eventType: "improve_dismiss",
                mode: mode,
                metadata: ["had_improved_code": !improvedCode.isEmpty]
            )
        }

        improvementTask?.cancel()
        improvementTask = nil
        resetImprovementState()
    }

    // MARK: - Replacement Actions

    /// Replace the current editor selection with the improved code.
    ///
    /// Uses ``TextReplacementService`` to paste via clipboard + ⌘V.
    /// Guards against pasting into Decode itself.
    func replaceInEditor() {
        guard !improvedCode.isEmpty else { return }

        replacementError = ""
        replacementConfirmation = ""
        isReplacing = true

        let mode = followUpContext.flatMap { ImprovementService.improvementMode(from: $0.mode) }
        let meta = improvementMetadata()

        Task {
            let result = await textReplacementService.replaceSelection(with: improvedCode)

            let replaceResult: String
            switch result {
            case .success:
                replacementConfirmation = "Replaced. Press ⌘Z in your editor to undo."
                isReplacing = false
                replaceResult = "success"
                #if DEBUG
                print("[DIAG_IMPROVE] replacement succeeded")
                #endif

            case .decodeIsFrontmost:
                replacementError = "Switch back to your editor before replacing code."
                isReplacing = false
                replaceResult = "decodeIsFrontmost"

            case .pasteEventFailed:
                replacementError = "Failed to send paste command. Check Accessibility permissions."
                isReplacing = false
                replaceResult = "pasteEventFailed"
            }

            var eventMeta = meta
            eventMeta["replace_result"] = replaceResult
            AnalyticsEventService.send(
                eventType: "improve_replace",
                mode: mode,
                metadata: eventMeta
            )
        }
    }

    /// Build LOC metadata for improvement analytics events.
    private func improvementMetadata() -> [String: Any] {
        let originalCode = followUpContext?.originalCode ?? ""
        let originalLOC = originalCode.components(separatedBy: "\n").count
        let improvedLOC = improvedCode.components(separatedBy: "\n").count
        return [
            "original_loc": originalLOC,
            "improved_loc": improvedLOC,
            "loc_delta": improvedLOC - originalLOC,
        ]
    }

    /// Reset all improvement-related state.
    private func resetImprovementState() {
        improvementRawText = ""
        improvementSummary = ""
        improvedCode = ""
        isImprovementLoading = false
        improvementError = ""
        replacementConfirmation = ""
        replacementError = ""
        isReplacing = false
    }

    /// Display a standalone error message in the HUD.
    ///
    /// Used when an error occurs before streaming starts (e.g., no permission,
    /// no text selected, AI not configured).
    func showError(_ message: String) {
        activeStreamTask?.cancel()
        followUpTask?.cancel()
        improvementTask?.cancel()
        activeStreamTask = nil
        followUpTask = nil
        improvementTask = nil

        explanationText = ""
        errorMessage = message
        sourceAppName = nil
        modeName = nil
        sessionFileName = nil
        explanationProfile = nil
        displayState = .error
        followUpContext = nil
        followUpAnswer = ""
        followUpError = ""
        followUpText = ""
        isFollowUpLoading = false
        resetImprovementState()
    }

    /// Dismiss the HUD and cancel any in-flight stream.
    func dismiss() {
        activeStreamTask?.cancel()
        followUpTask?.cancel()
        improvementTask?.cancel()
        activeStreamTask = nil
        followUpTask = nil
        improvementTask = nil

        displayState = .idle
        explanationText = ""
        errorMessage = ""
        sourceAppName = nil
        modeName = nil
        sessionFileName = nil
        explanationProfile = nil
        followUpContext = nil
        followUpAnswer = ""
        followUpError = ""
        followUpText = ""
        isFollowUpLoading = false
        resetImprovementState()
    }
}
