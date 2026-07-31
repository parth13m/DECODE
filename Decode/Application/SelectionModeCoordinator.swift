import AppKit
import Foundation

/// Orchestrates the Selection Mode flow: hotkey → capture → AI → HUD.
///
/// Thin coordinator that wires infrastructure services together without
/// containing business logic. Receives dependencies via init and iterates
/// a hotkey event stream, handling each `.explainSelection` event by:
///
/// 1. Checking AI provider availability
/// 2. Checking/requesting Accessibility permission
/// 3. Capturing selected text from the source app (PID from hotkey event)
/// 4. Building a prompt and calling `streamChat`
/// 5. Handing the token stream to the floating HUD
///
/// All errors are surfaced to the user via the HUD — no modal alerts.
@MainActor
final class SelectionModeCoordinator {

    // MARK: - Dependencies

    private let selectionCapture: any SelectionCaptureProtocol
    private let aiProvider: @MainActor () -> (any AIProviderProtocol)?
    private let hud: FloatingExplanationHUD
    private let toastManager: DecodeToastManager
    private let usageTracker: AIUsageTracker
    private let virtualSessionManager: VirtualSessionManager

    // MARK: - State

    private var listeningTask: Task<Void, Never>?

    /// Monotonically increasing counter. Incremented each time this coordinator
    /// dequeues a relevant hotkey event. Handlers compare their captured
    /// generation against the current value after each `await` — a mismatch
    /// means a newer request has arrived and the handler should exit early.
    private var requestGeneration: UInt64 = 0

    /// The currently executing request handler task. Cancelled when a newer
    /// event arrives so that `URLSession` tears down the in-flight HTTP
    /// request and the handler exits at the next suspension point.
    private var activeRequestTask: Task<Void, Never>?

    // MARK: - Init

    /// - Parameters:
    ///   - selectionCapture: Accessibility-based text capture service.
    ///   - aiProvider: Closure that returns the current AI provider, or nil if not configured.
    ///     A closure (not a stored reference) so the coordinator always reads the latest
    ///     provider after settings changes.
    ///   - hud: The floating explanation panel for displaying results and errors.
    ///   - usageTracker: Shared quota tracker for AI request limits.
    init(
        selectionCapture: any SelectionCaptureProtocol,
        aiProvider: @escaping @MainActor () -> (any AIProviderProtocol)?,
        hud: FloatingExplanationHUD,
        toastManager: DecodeToastManager,
        usageTracker: AIUsageTracker,
        virtualSessionManager: VirtualSessionManager
    ) {
        self.selectionCapture = selectionCapture
        self.aiProvider = aiProvider
        self.hud = hud
        self.toastManager = toastManager
        self.usageTracker = usageTracker
        self.virtualSessionManager = virtualSessionManager
    }

    // MARK: - Lifecycle

    /// Begin listening for hotkey events.
    ///
    /// Creates a long-lived task that iterates the provided stream. Each
    /// `.explainSelection` event triggers the full capture-and-explain flow.
    /// Call ``stopListening()`` to cancel.
    func startListening(hotkeyStream: AsyncStream<HotkeyEvent>) {
        stopListening()

        #if DEBUG
        print("[DEBUG Coordinator] startListening — awaiting hotkey events")
        #endif
        listeningTask = Task {
            for await event in hotkeyStream {
                #if DEBUG
                print("[DEBUG Coordinator] received action=\(event.action), pid=\(event.sourceAppPID ?? -1), app=\(event.sourceAppName ?? "nil")")
                #endif
                if Task.isCancelled { break }

                switch event.action {
                case .explainSelection:
                    // Increment generation and cancel the previous request so the
                    // loop is immediately free to dequeue the next event. This
                    // prevents ghost requests from queueing behind a slow handler.
                    requestGeneration += 1
                    activeRequestTask?.cancel()
                    let generation = requestGeneration
                    activeRequestTask = Task {
                        await handleExplainSelection(event: event, generation: generation)
                    }
                case .captureScreenshot, .askSessionQuestion, .openSession, .openWorkspace:
                    break  // Handled by other coordinators
                }
            }
        }
    }

    /// Stop listening for hotkey events.
    func stopListening() {
        listeningTask?.cancel()
        listeningTask = nil
        activeRequestTask?.cancel()
        activeRequestTask = nil
    }

    // MARK: - Selection Flow

    private func handleExplainSelection(event: HotkeyEvent, generation: UInt64) async {
        // 1. Check AI provider is configured.
        guard let provider = aiProvider() else {
            #if DEBUG
            print("[DEBUG Coordinator] no AI provider configured")
            #endif
            toastManager.show("Connecting to Decode Gateway. Please wait a moment and try again.", icon: "wifi.slash")
            return
        }

        // 2. Check Accessibility permission.
        guard selectionCapture.hasAccessibilityPermission() else {
            #if DEBUG
            print("[DEBUG Coordinator] no Accessibility permission")
            #endif
            selectionCapture.requestAccessibilityPermission()
            toastManager.show(
                "Accessibility permission required. Grant access in System Settings, then restart Decode.",
                icon: "lock.shield"
            )
            return
        }

        // 3. Capture selected text using the PID captured at hotkey time.
        guard let sourceAppPID = event.sourceAppPID else {
            #if DEBUG
            print("[DEBUG Coordinator] no source app PID")
            #endif
            toastManager.show("Could not identify the source application.", icon: "exclamationmark.triangle")
            return
        }

        let captureResult: SelectionCaptureResult?
        do {
            captureResult = try await selectionCapture.captureSelection(fromPID: sourceAppPID)
        } catch {
            guard generation == requestGeneration else { return }
            #if DEBUG
            print("[DEBUG Coordinator] capture threw: \(error.localizedDescription)")
            #endif
            toastManager.show("Failed to capture selection: \(error.localizedDescription)", icon: "exclamationmark.triangle")
            return
        }

        // Staleness check after capture await.
        guard generation == requestGeneration else {
            #if DEBUG
            print("[DEBUG Coordinator] request superseded after capture (gen=\(generation), current=\(requestGeneration))")
            #endif
            return
        }

        guard let result = captureResult else {
            #if DEBUG
            print("[DEBUG Coordinator] captureResult is nil — no text selected")
            #endif
            toastManager.show("No text selected. Highlight text in any app and try again.", icon: "text.cursor")
            return
        }

        // 3b. Reject whitespace-only selections.
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            #if DEBUG
            print("[DEBUG Coordinator] selection is whitespace-only — treating as empty")
            #endif
            toastManager.show("No text selected. Highlight text in any app and try again.", icon: "text.cursor")
            return
        }

        #if DEBUG
        print("[DEBUG Coordinator] captured \(result.text.count) chars from \(result.sourceApplicationName ?? "unknown")")
        #endif

        // Use the source app name from the hotkey event (captured synchronously)
        // rather than the capture result (which may re-query).
        let sourceAppName = event.sourceAppName ?? result.sourceApplicationName

        // 4. Truncate if over input limit.
        var text = result.text
        if text.count > AILimits.maxSelectedTextCharacters {
            text = String(text.prefix(AILimits.maxSelectedTextCharacters))
                + "\n[Truncated to \(AILimits.maxSelectedTextCharacters) characters]"
        }

        // 5. Check quota before making the AI request.
        guard usageTracker.tryConsumeRequest() else {
            toastManager.show(usageTracker.quotaExhaustedMessage, icon: "gauge.with.dots.needle.67percent")
            return
        }

        // 6. Build prompt and stream response.
        let dsaMode = UserDefaults.standard.bool(forKey: "dsaModeEnabled")
        let explanationProfile = dsaMode ? "dsa" : "general"
        var systemPrompt = buildSystemPrompt(sourceApp: sourceAppName, codeContent: text, dsaMode: dsaMode)
        let detectedFramework = ExplanationFramework.detect(fromContent: text)
        systemPrompt += RepresentationGuidance.guidance(
            snippet: text,
            framework: detectedFramework,
            containingEntityType: nil
        )

        // Virtual Session: inject working memory into system prompt.
        if virtualSessionManager.isEnabled,
           let wmBlock = virtualSessionManager.workingMemoryBlock() {
            systemPrompt += "\n\n\(wmBlock)"
        }

        let messages = [AIMessage(role: .user, content: text)]

        // Show HUD immediately so the user sees loading state while
        // the AI request is in flight.
        hud.showLoading(sourceApp: sourceAppName, mode: "selection", explanationProfile: explanationProfile)

        #if DEBUG
        let diagStreamRequestStart = CFAbsoluteTimeGetCurrent()
        print("[DIAG_COORD] streamChat request starting")
        #endif

        do {
            let stream = try await provider.streamChat(
                messages: messages,
                systemPrompt: systemPrompt,
                mode: "selection",
                contextTier: nil,
                explanationProfile: explanationProfile,
                language: nil
            )

            // Staleness check after streamChat await — don't show a stale
            // stream over a newer request's loading/streaming state.
            guard generation == requestGeneration else {
                #if DEBUG
                print("[DEBUG Coordinator] request superseded after streamChat (gen=\(generation), current=\(requestGeneration))")
                #endif
                return
            }

            #if DEBUG
            let diagStreamReady = CFAbsoluteTimeGetCurrent()
            let streamReadyMs = (diagStreamReady - diagStreamRequestStart) * 1000
            print("[DIAG_COORD] streamChat returned stream_ready_ms=\(String(format: "%.0f", streamReadyMs))")
            #endif

            let followUpCtx = ExplanationHUDViewModel.FollowUpContext(
                sourceContent: text,
                systemPrompt: systemPrompt,
                mode: "selection",
                aiProvider: provider,
                usageTracker: usageTracker,
                originalCode: text,
                explanationProfile: explanationProfile,
                language: nil,
                sessionContext: nil,
                pipelineQueryService: nil,
                pipelineConversationState: nil,
                pipelineFilePath: nil,
                pipelineEntityName: nil
            )

            // Virtual Session: record insight on stream completion.
            let vsManager = virtualSessionManager
            let capturedSourceApp = sourceAppName
            hud.showStream(stream, sourceApp: sourceAppName, followUpContext: followUpCtx) { explanationText in
                guard vsManager.isEnabled else { return }
                let understanding = VirtualSessionManager.extractUnderstanding(
                    from: explanationText,
                    sourceApp: capturedSourceApp
                )
                let context = InsightContext.minimal(sourceApp: capturedSourceApp)
                vsManager.recordInsight(
                    understanding: understanding,
                    mode: .selection,
                    context: context
                )
            }
        } catch {
            guard generation == requestGeneration else { return }
            #if DEBUG
            print("[DEBUG Coordinator] streamChat threw: \(error.localizedDescription)")
            #endif
            hud.showError("AI request failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Prompt

    private func buildSystemPrompt(sourceApp: String?, codeContent: String, dsaMode: Bool = false) -> String {
        let framework = ExplanationFramework.detect(fromContent: codeContent)

        var prompt = """
            You are Decode, a code explanation tool for macOS. The user selected text in \
            an application and wants to understand it.
            """

        prompt += framework.styleInstructions(dsaMode: dsaMode)

        if let app = sourceApp {
            prompt += "\n\nThe text was selected in \(app)."
        }

        return prompt
    }
}

