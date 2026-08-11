import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit

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
    private let visualContextExtractor: (any VisualContextExtracting)?
    private let profileIntelligenceService: ProfileIntelligenceService?

    // MARK: - State

    private var listeningTask: Task<Void, Never>?

    /// Monotonically increasing counter. Incremented each time this coordinator
    /// dequeues a relevant hotkey event. Handlers compare their captured
    /// generation against the current value after each `await` — a mismatch
    /// means a newer request has arrived and the handler should exit early.
    private var requestGeneration: UInt64 = 0

    /// Background vision extraction task, launched when the user starts typing
    /// a custom question. Cancelled on default explanation, cancel, or new request.
    private var pendingVisionTask: Task<VisualContext?, Never>?

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
        virtualSessionManager: VirtualSessionManager,
        visualContextExtractor: (any VisualContextExtracting)? = nil,
        profileIntelligenceService: ProfileIntelligenceService? = nil
    ) {
        self.selectionCapture = selectionCapture
        self.aiProvider = aiProvider
        self.hud = hud
        self.toastManager = toastManager
        self.usageTracker = usageTracker
        self.virtualSessionManager = virtualSessionManager
        self.visualContextExtractor = visualContextExtractor
        self.profileIntelligenceService = profileIntelligenceService
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
        pendingVisionTask?.cancel()
        pendingVisionTask = nil
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

        #if DEBUG
        let tSelectionStart = CFAbsoluteTimeGetCurrent()
        #endif
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
        #if DEBUG
        let tSelectionDone = CFAbsoluteTimeGetCurrent()
        #endif

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

        // 6. Capture screenshot for potential visual context (cheap, local only).
        //    Always captured when the extractor is available — the user's interaction
        //    with the intent bar (typing vs Enter/Space) determines whether the
        //    Vision model is actually called.
        let screenImage: CGImage?
        #if DEBUG
        var latencySelectionMs = (tSelectionDone - tSelectionStart) * 1000
        var latencyScreenCaptureMs: Double = 0
        var latencyVisionApiMs: Double = 0
        #endif
        if visualContextExtractor != nil {
            #if DEBUG
            let tScreenCaptureStart = CFAbsoluteTimeGetCurrent()
            #endif
            screenImage = await Self.captureScreenImage(forPID: sourceAppPID)
            #if DEBUG
            latencyScreenCaptureMs = (CFAbsoluteTimeGetCurrent() - tScreenCaptureStart) * 1000
            if screenImage == nil {
                EnhancedExplanationDebug.shared.lastError = "Screenshot capture failed for PID \(sourceAppPID)"
                EnhancedExplanationDebug.shared.lastTimestamp = Date()
            }
            #endif
            guard generation == requestGeneration else { return }
        } else {
            screenImage = nil
        }

        // 7. Collect user intent. If the user starts typing a custom question,
        //    launch vision extraction in the background so it runs in parallel
        //    with their typing. Default explanations (Enter/Space) skip vision entirely.
        let dsaMode = UserDefaults.standard.bool(forKey: "dsaModeEnabled")
        let explanationProfile = dsaMode ? "dsa" : "general"
        let executionContext = ExplanationExecutionContext(mode: "selection", explanationProfile: explanationProfile)

        // Cancel any leftover vision task from a previous interaction.
        pendingVisionTask?.cancel()
        pendingVisionTask = nil

        guard let intentText = await hud.collectIntent(
            sourceApp: sourceAppName,
            mode: "selection",
            explanationProfile: explanationProfile,
            onEditingStarted: { [weak self] in
                guard let self else { return }
                guard let image = screenImage, let extractor = self.visualContextExtractor else { return }
                #if DEBUG
                print("[EnhancedExplanation] user started typing — launching vision extraction in background")
                #endif
                self.pendingVisionTask = Task {
                    await extractor.extract(from: image)
                }
            }
        ) else {
            // User cancelled — clean up vision task and screenshot.
            pendingVisionTask?.cancel()
            pendingVisionTask = nil
            return
        }
        // Staleness check after intent collection await.
        guard generation == requestGeneration else {
            pendingVisionTask?.cancel()
            pendingVisionTask = nil
            return
        }

        // 8. Determine visual context based on intent type.
        let trimmedIntent = intentText.trimmingCharacters(in: .whitespacesAndNewlines)
        var visualContext: VisualContext?
        if !trimmedIntent.isEmpty, let visionTask = pendingVisionTask {
            // Custom question — await the background vision result.
            #if DEBUG
            let tVisionAwaitStart = CFAbsoluteTimeGetCurrent()
            print("[EnhancedExplanation] custom question submitted — awaiting vision result")
            #endif
            visualContext = await visionTask.value
            pendingVisionTask = nil
            #if DEBUG
            latencyVisionApiMs = (CFAbsoluteTimeGetCurrent() - tVisionAwaitStart) * 1000
            if let vc = visualContext {
                print("[EnhancedExplanation] vision complete (waited \(String(format: "%.0f", latencyVisionApiMs))ms after submit, \(vc.content.count) chars)")
                EnhancedExplanationDebug.shared.lastVisualContext = vc
                EnhancedExplanationDebug.shared.lastTimestamp = Date()
                EnhancedExplanationDebug.shared.lastError = nil
            } else {
                print("[EnhancedExplanation] vision returned nil")
                EnhancedExplanationDebug.shared.lastError = "Vision returned nil"
                EnhancedExplanationDebug.shared.lastTimestamp = Date()
            }
            #endif
            // Staleness check after vision await.
            guard generation == requestGeneration else { return }
        } else {
            // Default explanation or no screenshot — skip vision entirely.
            pendingVisionTask?.cancel()
            pendingVisionTask = nil
        }

        // 9. Build prompt and stream response.
        #if DEBUG
        let tPromptStart = CFAbsoluteTimeGetCurrent()
        #endif
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
            executionContext.virtualSession = true
        }

        // Profile Intelligence: inject user profile context into system prompt.
        var profileContext: String?
        if let service = profileIntelligenceService {
            let profile = await service.currentProfile()
            profileContext = ProfilePromptFormatter.format(profile)
            if let profileBlock = profileContext {
                systemPrompt += "\n\n\(profileBlock)"
            }
        }

        // Assemble user message — uses shared prompt composition.
        let formattedVC = visualContext.flatMap { $0.isEmpty ? nil : $0.formatted() }
        if formattedVC != nil { executionContext.vision = true }
        let userMessage = ExplanationFramework.userMessage(
            intent: intentText,
            code: text,
            visualContext: formattedVC
        )
        let messages = [AIMessage(role: .user, content: userMessage)]

        #if DEBUG
        let tPromptDone = CFAbsoluteTimeGetCurrent()
        let latencyPromptMs = (tPromptDone - tPromptStart) * 1000
        #endif

        // Show HUD loading state while the AI request is in flight.
        hud.showLoading(sourceApp: sourceAppName, mode: "selection", explanationProfile: explanationProfile, executionContext: executionContext)

        #if DEBUG
        let tExplainStart = CFAbsoluteTimeGetCurrent()
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
            let tExplainReady = CFAbsoluteTimeGetCurrent()
            let latencyExplainSetupMs = (tExplainReady - tExplainStart) * 1000
            let totalMs = (tExplainReady - tSelectionStart) * 1000

            // ── LATENCY BUDGET ──
            print("[LATENCY] ═══════════════════════════════════════════")
            print("[LATENCY]  CONDITIONAL VISION LATENCY BUDGET")
            print("[LATENCY] ═══════════════════════════════════════════")
            print("[LATENCY]")
            print("[LATENCY]  Selection capture:    \(String(format: "%6.0f", latencySelectionMs))ms")
            print("[LATENCY]  Screen capture:       \(String(format: "%6.0f", latencyScreenCaptureMs))ms")
            print("[LATENCY]  Vision (post-submit):  \(String(format: "%6.0f", latencyVisionApiMs))ms  (wait after Enter, 0=skipped/already done)")
            print("[LATENCY]  Prompt assembly:      \(String(format: "%6.0f", latencyPromptMs))ms")
            print("[LATENCY]  Explain stream setup: \(String(format: "%6.0f", latencyExplainSetupMs))ms")
            print("[LATENCY] ───────────────────────────────────────────")
            print("[LATENCY]  Total to first token: \(String(format: "%6.0f", totalMs))ms")
            print("[LATENCY]  Visual context:       \(visualContext != nil ? "YES" : "NO")")
            print("[LATENCY]  Intent type:          \(trimmedIntent.isEmpty ? "default" : "custom")")
            print("[LATENCY] ═══════════════════════════════════════════")
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
                sourceAppPID: event.sourceAppPID,
                pipelineQueryService: nil,
                pipelineConversationState: nil,
                pipelineFilePath: nil,
                pipelineEntityName: nil,
                pipelineSnippetStartLine: nil,
                pipelineSnippetEndLine: nil,
                profileContext: profileContext
            )

            // Virtual Session: record insight on stream completion.
            // Profile Intelligence: record observation at the same completion point.
            let vsManager = virtualSessionManager
            let capturedSourceApp = sourceAppName
            let profileService = profileIntelligenceService
            hud.showStream(stream, sourceApp: sourceAppName, followUpContext: followUpCtx) { explanationText in
                let context = InsightContext.minimal(sourceApp: capturedSourceApp)

                if vsManager.isEnabled {
                    let understanding = VirtualSessionManager.extractUnderstanding(
                        from: explanationText,
                        sourceApp: capturedSourceApp
                    )
                    vsManager.recordInsight(
                        understanding: understanding,
                        mode: .selection,
                        context: context
                    )
                }

                profileService?.recordObservation(
                    context: context,
                    mode: "selection",
                    observationType: .explanation
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

    // MARK: - Screen Capture (Enhanced Explanation)

    /// Capture the focused window for the given PID using ScreenCaptureKit.
    /// Returns nil if Screen Recording permission is denied or capture fails.
    @MainActor
    static func captureScreenImage(forPID pid: pid_t) async -> CGImage? {
        do {
            #if DEBUG
            let tWindowEnum = CFAbsoluteTimeGetCurrent()
            #endif
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            #if DEBUG
            let tWindowEnumDone = CFAbsoluteTimeGetCurrent()
            #endif

            guard let window = WindowSelector.selectWindow(from: content.windows, forPID: pid) else {
                #if DEBUG
                print("[VisualContext] no window found for PID \(pid)")
                #endif
                return nil
            }
            #if DEBUG
            let tWindowSelect = CFAbsoluteTimeGetCurrent()
            #endif

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = window.frame.width > 0 ? Int(window.frame.width) * 2 : 1920
            config.height = window.frame.height > 0 ? Int(window.frame.height) * 2 : 1080
            config.showsCursor = false

            #if DEBUG
            let tCaptureStart = CFAbsoluteTimeGetCurrent()
            #endif
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            #if DEBUG
            let tCaptureDone = CFAbsoluteTimeGetCurrent()
            print("[LATENCY] ── Screen Capture Breakdown ──")
            print("[LATENCY]   Window enumeration:  \(String(format: "%.0f", (tWindowEnumDone - tWindowEnum) * 1000))ms")
            print("[LATENCY]   Window selection:    \(String(format: "%.0f", (tWindowSelect - tWindowEnumDone) * 1000))ms")
            print("[LATENCY]   SCK capture:         \(String(format: "%.0f", (tCaptureDone - tCaptureStart) * 1000))ms")
            print("[LATENCY]   Capture total:       \(String(format: "%.0f", (tCaptureDone - tWindowEnum) * 1000))ms")
            print("[LATENCY]   Output: \(image.width)x\(image.height)")
            #endif
            return image
        } catch {
            #if DEBUG
            print("[VisualContext] screen capture failed: \(error.localizedDescription)")
            #endif
            return nil
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

        prompt += Self.visualContextGuidance

        return prompt
    }

    /// System prompt guidance for using visual context evidence.
    /// Appended unconditionally — a no-op when the user message has no [Visual Context] block.
    private static let visualContextGuidance = """

        If a [Visual Context]...[/Visual Context] block is present, another AI has examined \
        the user's full screen and identified what you would most likely misunderstand from \
        seeing only the highlighted code. This evidence is factual and grounded in what is \
        visible on screen. Integrate it into your reasoning — it may significantly change how \
        the code should be understood. Do not quote it verbatim or reference its source.
        """
}

