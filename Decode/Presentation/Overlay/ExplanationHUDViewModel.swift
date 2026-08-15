import AppKit
import ConsumerRuntime
import Foundation

/// The display state of the floating explanation HUD.
enum HUDDisplayState: Sendable {
    /// HUD is hidden, no content.
    case idle
    /// Waiting for the user to type a custom request or press Enter for the default explanation.
    case collectingIntent
    /// AI request in progress, no tokens received yet.
    case loading
    /// Tokens are streaming in. The `explanationText` property accumulates content.
    case streaming
    /// Streaming completed successfully.
    case complete
    /// An error occurred. The `errorMessage` property contains the description.
    case error
}

/// Identifies which response area a selectable block belongs to.
/// Prevents ID collisions between explanation and follow-up answer blocks,
/// since ExplanationTagParser assigns IDs 0,1,2... independently per call.
enum SelectableBlockSource: Hashable, Sendable {
    case explanation
    case followUpQuestion
    case followUpAnswer
}

/// Unique identity for a selectable text block across the entire HUD.
struct SelectableBlockID: Hashable, Sendable {
    let source: SelectableBlockSource
    let index: Int
}

/// The user's current text selection from an AI response.
struct ResponseSelection: Sendable {
    /// Which block the selection came from.
    let blockID: SelectableBlockID
    /// The selected text, truncated to AILimits.maxResponseSelectionCharacters.
    let text: String
    /// Whether the selection came from a follow-up (question or answer).
    var isFollowUp: Bool {
        blockID.source == .followUpAnswer || blockID.source == .followUpQuestion
    }

    /// Human-readable description of the selection source for augmented question wording.
    var sourceDescription: String {
        switch blockID.source {
        case .explanation: return "your previous response"
        case .followUpQuestion: return "your follow-up question"
        case .followUpAnswer: return "your follow-up answer"
        }
    }
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

    /// Execution context recording which capabilities contributed to this explanation.
    /// Set by ``showLoading`` and used by the header to display the execution context.
    private(set) var executionContext: ExplanationExecutionContext?

    /// Whether the HUD should be visible.
    var isVisible: Bool { displayState != .idle }

    /// Whether the HUD is currently receiving streamed content.
    var isStreaming: Bool { displayState == .loading || displayState == .streaming }

    // MARK: - Response Selection (Reply ↩)

    /// The user's current pending text selection from an AI response.
    /// Set when the user highlights text; drives Reply button visibility.
    /// Does NOT drive the replying-to indicator, placeholder, or augmentation.
    private(set) var responseSelection: ResponseSelection?

    /// The block ID of the most recent selection event. Used for stale-selection
    /// protection: a deselection callback from block A must not clear a newer
    /// selection from block B. Also used by SelectableTextView to clear native
    /// selection in other blocks (single-selection enforcement).
    private(set) var activeSelectionBlockID: SelectableBlockID?

    /// The committed Reply context. Created ONLY when the user clicks Reply.
    /// Drives: replying-to indicator, "Ask about this selection..." placeholder,
    /// Follow-Up prompt augmentation, and Follow-Up focus.
    private(set) var anchoredResponseSelection: ResponseSelection?

    /// Set to true when Reply is tapped, observed by the view to transfer focus.
    /// Reset to false after the view has consumed it.
    var replyActivated: Bool = false

    /// Called by SelectableTextView when the user's selection changes in a block.
    ///
    /// Stale-selection protection: if `text` is nil (deselection), only clear
    /// the pending selection if the callback's blockID matches the active block.
    func handleSelectionChange(blockID: SelectableBlockID, text: String?) {
        if let text, !text.isEmpty {
            let truncated = String(text.prefix(AILimits.maxResponseSelectionCharacters))
            responseSelection = ResponseSelection(blockID: blockID, text: truncated)
            activeSelectionBlockID = blockID
            #if DEBUG
            print("[AnchoredFollowUp] selection captured blockID=\(blockID.source):\(blockID.index) textLength=\(truncated.count)")
            #endif
        } else {
            // Deselection: only clear if it's from the currently active block.
            if activeSelectionBlockID == blockID {
                #if DEBUG
                print("[AnchoredFollowUp] genuine deselection from active block \(blockID.source):\(blockID.index)")
                #endif
                responseSelection = nil
                activeSelectionBlockID = nil
            } else {
                #if DEBUG
                print("[AnchoredFollowUp] stale deselection ignored from \(blockID.source):\(blockID.index), active=\(String(describing: activeSelectionBlockID))")
                #endif
            }
        }
    }

    /// Activates the Reply flow: commits the pending selection as the anchored
    /// reply context, clears the pending selection, and focuses the follow-up input.
    func activateReply() {
        guard let pending = responseSelection else { return }
        anchoredResponseSelection = pending
        responseSelection = nil
        activeSelectionBlockID = nil
        followUpText = ""
        replyActivated = true
        #if DEBUG
        print("[AnchoredFollowUp] Reply activated textLength=\(pending.text.count) blockID=\(pending.blockID.source):\(pending.blockID.index)")
        #endif
    }

    /// Clears both pending and anchored response selection state.
    func clearResponseSelection() {
        #if DEBUG
        print("[AnchoredFollowUp] clearResponseSelection called, hadPending=\(responseSelection != nil) hadAnchored=\(anchoredResponseSelection != nil)")
        #endif
        responseSelection = nil
        anchoredResponseSelection = nil
        activeSelectionBlockID = nil
        replyActivated = false
    }

    // MARK: - Intent Collection State

    /// User's intent text (bound to TextField in collectingIntent state).
    var intentText: String = ""

    /// Whether the user has started typing (transitions from idle→editing state).
    /// In idle state, the HUD container owns keyboard (Enter/Space → default).
    /// In editing state, the TextField owns keyboard (normal text editing).
    var isEditingIntent: Bool = false

    /// Continuation for the async collectIntent flow. Resumed when the user
    /// submits (empty string = default, non-empty = custom) or cancels (nil).
    private var intentContinuation: CheckedContinuation<String?, Never>?

    /// One-shot callback invoked when the user transitions from idle to editing
    /// (first printable character). Used by coordinators to start background work
    /// (e.g., vision extraction) only when a custom question is being typed.
    /// Automatically nilled after firing.
    var onEditingStarted: (@MainActor () -> Void)?

    /// Prepare the HUD for intent collection (synchronous state reset).
    /// Call this before showing the panel, then call ``awaitIntentSubmission()``
    /// to suspend until the user submits or cancels.
    func prepareIntentCollection(
        sourceApp: String?,
        mode: String? = nil,
        sessionFile: String? = nil,
        explanationProfile: String? = nil
    ) {
        // Cancel any previous intent collection.
        cancelIntentIfNeeded()

        // Reset state for intent collection.
        activeStreamTask?.cancel()
        followUpTask?.cancel()
        improvementTask?.cancel()

        explanationText = ""
        errorMessage = ""
        sourceAppName = sourceApp
        modeName = mode
        sessionFileName = sessionFile
        self.explanationProfile = explanationProfile
        intentText = ""
        isEditingIntent = false
        displayState = .collectingIntent

        followUpAnswer = ""
        followUpError = ""
        followUpText = ""
        isFollowUpLoading = false
        followUpContext = nil
        resetImprovementState()
        clearResponseSelection()
    }

    /// Suspend until the user submits their intent or cancels.
    /// Returns the user's text (empty = default, non-empty = custom), or nil if cancelled.
    func awaitIntentSubmission() async -> String? {
        await withCheckedContinuation { continuation in
            intentContinuation = continuation
        }
    }

    /// Transition from idle to editing state without inserting text.
    ///
    /// Used by the AppKit key event monitor, which re-posts the original
    /// key event so the TextField receives it through the normal responder
    /// chain — producing native insertion behavior with no selection.
    func transitionToEditing() {
        intentText = ""
        isEditingIntent = true
        let callback = onEditingStarted
        onEditingStarted = nil
        callback?()
    }

    /// Transition from idle to editing state with the first character.
    ///
    /// Used by the SwiftUI `.onKeyPress` fallback path. Sets the character
    /// directly since there's no NSEvent to re-post.
    func beginEditing(with character: String) {
        intentText = character
        isEditingIntent = true
        let callback = onEditingStarted
        onEditingStarted = nil
        callback?()
    }

    /// Called when the user submits their intent (Enter key or button).
    func submitIntent() {
        let text = intentText.trimmingCharacters(in: .whitespacesAndNewlines)
        onEditingStarted = nil
        intentContinuation?.resume(returning: text)
        intentContinuation = nil
    }

    /// Called when the user cancels intent collection (Escape or close).
    func cancelIntent() {
        cancelIntentIfNeeded()
        displayState = .idle
    }

    private func cancelIntentIfNeeded() {
        onEditingStarted = nil
        intentContinuation?.resume(returning: nil)
        intentContinuation = nil
    }

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

        /// PID of the app the user was in when the hotkey was triggered.
        /// Used by Replace to re-activate the source editor before pasting.
        let sourceAppPID: pid_t?

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
        /// Used by legacy entity-based follow-up path. `nil` for snippet-based queries.
        let pipelineEntityName: String?

        /// Snippet start line for snippet-based pipeline queries.
        /// Used by follow-up and improve when the initial query used SnippetReference.
        let pipelineSnippetStartLine: Int?

        /// Snippet end line for snippet-based pipeline queries.
        let pipelineSnippetEndLine: Int?

        /// Formatted profile context string for injection into follow-up
        /// and improvement prompts. `nil` when profile is empty or below
        /// confidence threshold.
        let profileContext: String?
    }

    // MARK: - Follow-up Prompt

    /// Dedicated system prompt for follow-up questions. Unlike the explanation
    /// prompt, this instructs the model to answer concisely without regenerating
    /// Purpose/Flow/Example/Important Lines/Summary sections.
    /// Also used by History follow-ups via ``historyFollowUpSystemPrompt``.
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

    /// The follow-up system prompt, exposed for use by History follow-ups.
    static let historyFollowUpSystemPrompt: String = followUpSystemPrompt

    // MARK: - History Recording

    /// Callback invoked when an explanation completes successfully.
    /// Parameters: mode, originalCode, explanation, sourceAppName, fileName, language, explanationProfile.
    /// Set by AppDependencies to record the explanation in HistoryManager.
    var onExplanationRecorded: ((@MainActor (
        _ mode: String, _ originalCode: String, _ explanation: String,
        _ sourceAppName: String?, _ fileName: String?,
        _ language: String?, _ explanationProfile: String?,
        _ customQuestion: String?
    ) -> Void))?

    /// Callback invoked when a follow-up completes successfully.
    /// Set by AppDependencies to record the follow-up in HistoryManager.
    var onFollowUpRecorded: ((@MainActor (_ question: String, _ answer: String) -> Void))?

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

    /// The optimisation goal selected by the user for the current improvement.
    private(set) var selectedOptimisationGoal: OptimisationGoal?

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

    // MARK: - Note State

    /// Confirmation message shown after a note is saved.
    private(set) var noteSavedConfirmation: String = ""

    /// Whether a note can be saved (explanation complete + text exists).
    var canSaveNote: Bool {
        displayState == .complete && !explanationText.isEmpty
    }

    /// Note service reference, set by AppDependencies.
    var noteService: NoteService?

    // MARK: - Feedback

    /// Feedback manager reference, set by AppDependencies.
    var feedbackManager: FeedbackManager?

    /// Save the current explanation as a note.
    func saveNote() {
        guard canSaveNote, let service = noteService else { return }

        let code = followUpContext?.originalCode ?? ""
        let explanation = explanationText
        let language = followUpContext?.language
        let mode = followUpContext?.mode
        let filePath = followUpContext?.pipelineFilePath

        Task {
            do {
                let note = try await service.saveNote(
                    selectedCode: code,
                    explanation: explanation,
                    language: language,
                    mode: mode,
                    workspacePath: nil,
                    filePath: filePath
                )
                noteSavedConfirmation = "Saved: \(note.title)"

                // Auto-dismiss confirmation after 3 seconds.
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    noteSavedConfirmation = ""
                }
            } catch {
                #if DEBUG
                print("[DEBUG NOTE] save failed: \(error.localizedDescription)")
                #endif
            }
        }
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
    func showLoading(sourceApp: String?, mode: String? = nil, sessionFile: String? = nil, explanationProfile: String? = nil, executionContext: ExplanationExecutionContext? = nil) {
        activeStreamTask?.cancel()
        followUpTask?.cancel()
        improvementTask?.cancel()

        explanationText = ""
        errorMessage = ""
        sourceAppName = sourceApp
        modeName = mode
        sessionFileName = sessionFile
        self.explanationProfile = explanationProfile
        self.executionContext = executionContext
        displayState = .loading

        followUpAnswer = ""
        followUpError = ""
        followUpText = ""
        isFollowUpLoading = false
        followUpContext = nil
        resetImprovementState()
        clearResponseSelection()
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
        clearResponseSelection()

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

                    // Record in History.
                    let historyCode = followUpContext?.originalCode
                        ?? followUpContext?.sourceContent ?? ""
                    let trimmedIntent = intentText.trimmingCharacters(in: .whitespacesAndNewlines)
                    onExplanationRecorded?(
                        modeName ?? "unknown",
                        historyCode,
                        explanationText,
                        sourceAppName,
                        sessionFileName,
                        followUpContext?.language,
                        explanationProfile,
                        trimmedIntent.isEmpty ? nil : trimmedIntent
                    )

                    // Trigger feedback scheduling for explanations.
                    feedbackManager?.recordExplanation(metadata: buildFeedbackMetadata())
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

    /// Builds the augmented question string when an anchored reply context exists.
    private func buildAugmentedQuestion(_ question: String) -> String {
        guard let selection = anchoredResponseSelection else {
            return question
        }
        #if DEBUG
        print("[AnchoredFollowUp] augmented question includes anchored selection selectionLength=\(selection.text.count) source=\(selection.blockID.source)")
        #endif
        return "Regarding this specific part of \(selection.sourceDescription): \"\(selection.text)\"\n\n\(question)"
    }

    /// Ask a follow-up question using the context from the original request.
    ///
    /// Attempts the pipeline path first when pipeline state is available
    /// (ConversationState round-trip through FollowUpReasoningEngine).
    /// Falls back to the legacy 3-message conversation path on pipeline
    /// failure or when pipeline state is absent.
    func askFollowUp() {
        let rawQuestion = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawQuestion.isEmpty else { return }
        #if DEBUG
        print("[AnchoredFollowUp] askFollowUp called anchoredPresent=\(anchoredResponseSelection != nil) anchoredLength=\(anchoredResponseSelection?.text.count ?? 0) questionLength=\(rawQuestion.count)")
        #endif
        let question = buildAugmentedQuestion(rawQuestion)
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
               let filePath = ctx.pipelineFilePath {
                let capturedProfileCtx = ctx.profileContext
                let capturedSnippet = ctx.originalCode

                // Use snippet-based follow-up when line range is available,
                // fall back to entity-based for legacy contexts.
                let result: PipelineQueryResult
                if let startLine = ctx.pipelineSnippetStartLine,
                   let endLine = ctx.pipelineSnippetEndLine {
                    result = await Task.detached {
                        await service.queryFollowUpBySnippet(
                            filePath: filePath,
                            startLine: startLine,
                            endLine: endLine,
                            question: question,
                            conversationState: conversationState,
                            profileContext: capturedProfileCtx,
                            snippetText: capturedSnippet
                        )
                    }.value
                } else if let entityName = ctx.pipelineEntityName {
                    result = await Task.detached {
                        await service.queryFollowUp(
                            filePath: filePath,
                            entityName: entityName,
                            question: question,
                            conversationState: conversationState,
                            profileContext: capturedProfileCtx,
                            snippetText: capturedSnippet
                        )
                    }.value
                } else {
                    // No snippet or entity info — fall through to legacy.
                    await askFollowUpLegacy(question: question, rawQuestion: rawQuestion, ctx: ctx)
                    return
                }

                if case .success(let understanding) = result {
                    if !Task.isCancelled {
                        followUpAnswer = understanding.content
                        // Update conversation state for subsequent follow-ups.
                        followUpContext?.pipelineConversationState = understanding.conversationState
                        isFollowUpLoading = false

                        // Record in History.
                        onFollowUpRecorded?(rawQuestion, understanding.content)

                        followUpText = ""
                        clearResponseSelection()
                    }
                    return
                }

                #if DEBUG
                print("[DEBUG HUD] pipeline follow-up failed, falling back to legacy path: \(result)")
                #endif
                // Fall through to legacy path.
            }

            // Legacy path: 3-message conversation via streamChat.
            await askFollowUpLegacy(question: question, rawQuestion: rawQuestion, ctx: ctx)
        }
    }

    /// Legacy follow-up path: builds a 3-message conversation and streams the response.
    private func askFollowUpLegacy(question: String, rawQuestion: String, ctx: FollowUpContext) async {
        let messages: [AIMessage] = [
            AIMessage(role: .user, content: ctx.sourceContent),
            AIMessage(role: .assistant, content: explanationText),
            AIMessage(role: .user, content: question),
        ]

        // Combine the original session context with follow-up formatting rules
        // so the model retains file structure knowledge while answering concisely.
        var combinedSystemPrompt = ctx.systemPrompt + "\n\n---\n\n" + Self.followUpSystemPrompt

        // Profile Intelligence: inject profile context into follow-up prompt.
        if let profileBlock = ctx.profileContext {
            combinedSystemPrompt += "\n\n\(profileBlock)"
        }

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

                // Record in History (use rawQuestion, not the augmented prompt).
                if !followUpAnswer.isEmpty {
                    onFollowUpRecorded?(rawQuestion, followUpAnswer)
                }

                followUpText = ""
                clearResponseSelection()
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
    ///
    /// - Parameter goal: The optimisation goal selected by the user.
    func requestImprovement(goal: OptimisationGoal = .balanced) {
        guard let ctx = followUpContext,
              let originalCode = ctx.originalCode
        else { return }

        // Check quota.
        guard ctx.usageTracker.tryConsumeRequest() else {
            improvementError = ctx.usageTracker.quotaExhaustedMessage
            return
        }

        improvementTask?.cancel()

        selectedOptimisationGoal = goal
        isImprovementLoading = true
        improvementRawText = ""
        improvementSummary = ""
        improvedCode = ""
        improvementError = ""

        improvementTask = Task {
            // Pipeline path: attempt when pipeline state is available.
            if let service = ctx.pipelineQueryService,
               let filePath = ctx.pipelineFilePath {
                let capturedProfileCtx = ctx.profileContext

                // Use snippet-based improve when line range is available,
                // fall back to entity-based for legacy contexts.
                let result: PipelineQueryResult
                if let startLine = ctx.pipelineSnippetStartLine,
                   let endLine = ctx.pipelineSnippetEndLine {
                    result = await Task.detached {
                        await service.queryBySnippet(
                            filePath: filePath,
                            startLine: startLine,
                            endLine: endLine,
                            purpose: "improve",
                            profileContext: capturedProfileCtx
                        )
                    }.value
                } else if let entityName = ctx.pipelineEntityName {
                    result = await Task.detached {
                        await service.query(
                            filePath: filePath,
                            entityName: entityName,
                            purpose: "improve",
                            profileContext: capturedProfileCtx
                        )
                    }.value
                } else {
                    await requestImprovementLegacy(originalCode: originalCode, ctx: ctx, goal: goal)
                    return
                }

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

                        // Trigger feedback for optimisation.
                        feedbackManager?.recordOptimisation(metadata: buildFeedbackMetadata(optimisationGoal: selectedOptimisationGoal))
                    }
                    return
                }
                // Fall through to legacy path.
            }

            await requestImprovementLegacy(originalCode: originalCode, ctx: ctx, goal: goal)
        }
    }

    /// Legacy improvement path: direct AI provider call with streaming response.
    ///
    /// Used when the pipeline is unavailable or fails. Preserves the original
    /// Selection and Session mode improvement flows exactly.
    private func requestImprovementLegacy(originalCode: String, ctx: FollowUpContext, goal: OptimisationGoal = .balanced) async {
        let messages: [AIMessage] = [
            AIMessage(role: .user, content: originalCode),
        ]

        let mode = ImprovementService.improvementMode(from: ctx.mode)

        // Profile Intelligence: inject profile context into improvement prompt.
        var improvementPrompt = ImprovementService.systemPrompt(for: goal)
        if let profileBlock = ctx.profileContext {
            improvementPrompt += "\n\n\(profileBlock)"
        }

        do {
            let stream = try await ctx.aiProvider.streamChat(
                messages: messages,
                systemPrompt: improvementPrompt,
                mode: mode,
                contextTier: nil,
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

                // Trigger feedback for optimisation.
                feedbackManager?.recordOptimisation(metadata: buildFeedbackMetadata(optimisationGoal: goal))
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
            let result = await textReplacementService.replaceSelection(with: improvedCode, sourceAppPID: followUpContext?.sourceAppPID)

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

    /// Build metadata for feedback analytics events.
    private func buildFeedbackMetadata(optimisationGoal: OptimisationGoal? = nil) -> [String: Any] {
        var meta: [String: Any] = [:]
        if let mode = followUpContext?.mode { meta["mode"] = mode }
        if let language = followUpContext?.language { meta["language"] = language }
        if let profile = followUpContext?.explanationProfile { meta["explanation_profile"] = profile }
        if let goal = optimisationGoal { meta["optimisation_goal"] = goal.rawValue }
        return meta
    }

    /// Reset all improvement-related state.
    private func resetImprovementState() {
        improvementRawText = ""
        improvementSummary = ""
        improvedCode = ""
        isImprovementLoading = false
        improvementError = ""
        selectedOptimisationGoal = nil
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
        executionContext = nil
        displayState = .error
        followUpContext = nil
        followUpAnswer = ""
        followUpError = ""
        followUpText = ""
        isFollowUpLoading = false
        resetImprovementState()
        clearResponseSelection()
    }

    /// Dismiss the HUD and cancel any in-flight stream.
    func dismiss() {
        cancelIntentIfNeeded()
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
        executionContext = nil
        followUpContext = nil
        followUpAnswer = ""
        followUpError = ""
        followUpText = ""
        isFollowUpLoading = false
        noteSavedConfirmation = ""
        feedbackManager?.reset()
        resetImprovementState()
        clearResponseSelection()
    }
}
