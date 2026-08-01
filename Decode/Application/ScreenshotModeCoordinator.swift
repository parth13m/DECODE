import AppKit
import Foundation

/// Orchestrates the Screenshot Mode flow: hotkey → screen capture → OCR → AI → HUD.
///
/// Mirrors ``SelectionModeCoordinator`` structure. Receives `.captureScreenshot`
/// events from the shared hotkey stream and runs the pipeline:
///
/// 1. Checking Screen Recording permission
/// 2. Capturing the screen (Phase 1: full active screen; Phase 2: region selection)
/// 3. Running OCR via Vision framework
/// 4. Building a prompt and calling `streamChat`
/// 5. Handing the token stream to the floating HUD
///
/// All errors are surfaced to the user via the HUD — no modal alerts.
@MainActor
final class ScreenshotModeCoordinator {

    // MARK: - Dependencies

    private let screenCapture: any ScreenCaptureProtocol
    private let ocrService: any OCRServiceProtocol
    private let aiProvider: @MainActor () -> (any AIProviderProtocol)?
    private let hud: FloatingExplanationHUD
    private let toastManager: DecodeToastManager
    private let usageTracker: AIUsageTracker
    private let virtualSessionManager: VirtualSessionManager
    private let visualContextExtractor: (any VisualContextExtracting)?

    // MARK: - State

    private var listeningTask: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0
    private var activeRequestTask: Task<Void, Never>?

    // MARK: - Init

    init(
        screenCapture: any ScreenCaptureProtocol,
        ocrService: any OCRServiceProtocol,
        aiProvider: @escaping @MainActor () -> (any AIProviderProtocol)?,
        hud: FloatingExplanationHUD,
        toastManager: DecodeToastManager,
        usageTracker: AIUsageTracker,
        virtualSessionManager: VirtualSessionManager,
        visualContextExtractor: (any VisualContextExtracting)? = nil
    ) {
        self.screenCapture = screenCapture
        self.ocrService = ocrService
        self.aiProvider = aiProvider
        self.hud = hud
        self.toastManager = toastManager
        self.usageTracker = usageTracker
        self.virtualSessionManager = virtualSessionManager
        self.visualContextExtractor = visualContextExtractor
    }

    // MARK: - Lifecycle

    /// Begin listening for screenshot hotkey events.
    ///
    /// Creates a long-lived task that iterates the provided stream. Only
    /// `.captureScreenshot` events are handled; all others are ignored.
    func startListening(hotkeyStream: AsyncStream<HotkeyEvent>) {
        stopListening()

        #if DEBUG
        print("[DEBUG ScreenshotCoordinator] startListening — awaiting hotkey events")
        #endif
        listeningTask = Task {
            for await event in hotkeyStream {
                if Task.isCancelled { break }

                switch event.action {
                case .captureScreenshot:
                    requestGeneration += 1
                    activeRequestTask?.cancel()
                    let generation = requestGeneration
                    activeRequestTask = Task {
                        await handleCaptureScreenshot(event: event, generation: generation)
                    }
                case .explainSelection, .askSessionQuestion, .openSession, .openWorkspace:
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

    // MARK: - Screenshot Flow

    private func handleCaptureScreenshot(event: HotkeyEvent, generation: UInt64) async {
        // 1. Check AI provider is configured.
        guard let provider = aiProvider() else {
            #if DEBUG
            print("[DEBUG ScreenshotCoordinator] no AI provider configured")
            #endif
            toastManager.show("Connecting to Decode Gateway. Please wait a moment and try again.", icon: "wifi.slash")
            return
        }

        // 2. Check Screen Recording permission.
        if !CGPreflightScreenCaptureAccess() {
            #if DEBUG
            print("[DEBUG ScreenshotCoordinator] Screen Recording permission not granted — requesting")
            #endif
            CGRequestScreenCaptureAccess()
            toastManager.show(
                "Screen Recording permission required. Grant access in System Settings → Privacy & Security → Screen Recording, then restart Decode.",
                icon: "lock.shield"
            )
            return
        }

        // 3. Capture the screen (nil means user cancelled or capture failed — both silent).
        #if DEBUG
        print("[DEBUG ScreenshotCoordinator] capturing screen...")
        #endif
        guard let captureResult = await screenCapture.captureScreenRegion() else {
            #if DEBUG
            print("[DEBUG ScreenshotCoordinator] screen capture returned nil (cancelled or failed)")
            #endif
            return
        }

        // Staleness check after screen capture await.
        guard generation == requestGeneration else {
            #if DEBUG
            print("[DEBUG ScreenshotCoordinator] request superseded after capture (gen=\(generation), current=\(requestGeneration))")
            #endif
            return
        }

        // 4. Run OCR and visual context extraction in parallel.
        #if DEBUG
        print("[DEBUG ScreenshotCoordinator] running OCR on \(captureResult.image.width)x\(captureResult.image.height) image...")
        #endif

        let enhancedEnabled = UserDefaults.standard.bool(forKey: "enhancedExplanationEnabled")
        let recognizedText: String
        var visualContext: VisualContext?

        #if DEBUG
        print("[EnhancedExplanation] Screenshot Mode: enabled=\(enhancedEnabled), extractor=\(visualContextExtractor != nil ? "present" : "NIL")")
        #endif

        if enhancedEnabled, let extractor = visualContextExtractor {
            // Run OCR and vision extraction in parallel.
            #if DEBUG
            let parallelStart = CFAbsoluteTimeGetCurrent()
            print("[EnhancedExplanation] running OCR + vision extraction in parallel...")
            #endif
            async let ocrResult = ocrService.recognizeText(in: captureResult.image)
            async let vcResult = extractor.extract(from: captureResult.image)

            do {
                recognizedText = try await ocrResult
            } catch {
                guard generation == requestGeneration else { return }
                #if DEBUG
                print("[DEBUG ScreenshotCoordinator] OCR failed: \(error.localizedDescription)")
                #endif
                toastManager.show("OCR failed: \(error.localizedDescription)", icon: "exclamationmark.triangle")
                return
            }
            visualContext = await vcResult
            #if DEBUG
            let parallelMs = (CFAbsoluteTimeGetCurrent() - parallelStart) * 1000
            if let vc = visualContext {
                print("[EnhancedExplanation] parallel complete in \(String(format: "%.0f", parallelMs))ms — \(vc.items.count) evidence items:")
                for item in vc.items {
                    print("[EnhancedExplanation]   \(item.type): \(item.content)")
                }
                EnhancedExplanationDebug.shared.lastVisualContext = vc
                EnhancedExplanationDebug.shared.lastTimestamp = Date()
                EnhancedExplanationDebug.shared.lastError = nil
            } else {
                print("[EnhancedExplanation] parallel complete in \(String(format: "%.0f", parallelMs))ms — vision returned nil")
                EnhancedExplanationDebug.shared.lastError = "Vision returned nil after \(String(format: "%.0f", parallelMs))ms"
                EnhancedExplanationDebug.shared.lastTimestamp = Date()
            }
            #endif
        } else if enhancedEnabled {
            #if DEBUG
            print("[EnhancedExplanation] toggle ON but extractor is NIL — is GROQ_API_KEY set?")
            #endif
            do {
                recognizedText = try await ocrService.recognizeText(in: captureResult.image)
            } catch {
                guard generation == requestGeneration else { return }
                #if DEBUG
                print("[DEBUG ScreenshotCoordinator] OCR failed: \(error.localizedDescription)")
                #endif
                toastManager.show("OCR failed: \(error.localizedDescription)", icon: "exclamationmark.triangle")
                return
            }
        } else {
            do {
                recognizedText = try await ocrService.recognizeText(in: captureResult.image)
            } catch {
                guard generation == requestGeneration else { return }
                #if DEBUG
                print("[DEBUG ScreenshotCoordinator] OCR failed: \(error.localizedDescription)")
                #endif
                toastManager.show("OCR failed: \(error.localizedDescription)", icon: "exclamationmark.triangle")
                return
            }
        }

        // Staleness check after OCR/vision await.
        guard generation == requestGeneration else {
            #if DEBUG
            print("[DEBUG ScreenshotCoordinator] request superseded after OCR (gen=\(generation), current=\(requestGeneration))")
            #endif
            return
        }

        guard !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            #if DEBUG
            print("[DEBUG ScreenshotCoordinator] OCR returned empty text")
            #endif
            toastManager.show("No text found in the captured screen region.", icon: "text.cursor")
            return
        }

        #if DEBUG
        print("[DEBUG ScreenshotCoordinator] OCR recognized \(recognizedText.count) chars")
        #endif

        // 5. Truncate OCR output if over input limit.
        var ocrText = recognizedText
        if ocrText.count > AILimits.maxOCRTextCharacters {
            ocrText = String(ocrText.prefix(AILimits.maxOCRTextCharacters))
                + "\n[Truncated to \(AILimits.maxOCRTextCharacters) characters]"
        }

        // 6. Check quota before making the AI request.
        guard usageTracker.tryConsumeRequest() else {
            toastManager.show(usageTracker.quotaExhaustedMessage, icon: "gauge.with.dots.needle.67percent")
            return
        }

        // 7. Build prompt and stream response.
        let sourceAppName = event.sourceAppName
        let dsaMode = UserDefaults.standard.bool(forKey: "dsaModeEnabled")
        let explanationProfile = dsaMode ? "dsa" : "general"
        var systemPrompt = buildSystemPrompt(sourceApp: sourceAppName, ocrContent: ocrText, dsaMode: dsaMode)

        // Virtual Session: inject working memory into system prompt.
        if virtualSessionManager.isEnabled,
           let wmBlock = virtualSessionManager.workingMemoryBlock() {
            systemPrompt += "\n\n\(wmBlock)"
        }

        let detectedFramework = ExplanationFramework.detect(fromContent: ocrText)

        // Assemble user message with visual context evidence.
        let userMessage: String
        if let vc = visualContext, !vc.isEmpty {
            userMessage = "[Context]\n\(vc.formatted())\n[/Context]\n\n\(ocrText)"
            #if DEBUG
            print("[EnhancedExplanation] final prompt contains Visual Context: YES (\(vc.items.count) items, \(vc.formatted().count) chars)")
            #endif
        } else {
            userMessage = ocrText
            #if DEBUG
            print("[EnhancedExplanation] final prompt contains Visual Context: NO")
            #endif
        }
        let messages = [AIMessage(role: .user, content: userMessage)]

        // Show HUD immediately so the user sees loading state while
        // the AI request is in flight.
        hud.showLoading(sourceApp: sourceAppName, mode: "screenshot", explanationProfile: explanationProfile)

        do {
            let stream = try await provider.streamChat(
                messages: messages,
                systemPrompt: systemPrompt,
                mode: "screenshot",
                contextTier: nil,
                explanationProfile: explanationProfile,
                language: nil
            )

            // Staleness check after streamChat await.
            guard generation == requestGeneration else {
                #if DEBUG
                print("[DEBUG ScreenshotCoordinator] request superseded after streamChat (gen=\(generation), current=\(requestGeneration))")
                #endif
                return
            }

            let followUpCtx = ExplanationHUDViewModel.FollowUpContext(
                sourceContent: ocrText,
                systemPrompt: systemPrompt,
                mode: "screenshot",
                aiProvider: provider,
                usageTracker: usageTracker,
                originalCode: nil,
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
                    mode: .screenshot,
                    context: context
                )
            }
        } catch {
            guard generation == requestGeneration else { return }
            #if DEBUG
            print("[DEBUG ScreenshotCoordinator] streamChat threw: \(error.localizedDescription)")
            #endif
            hud.showError("AI request failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Prompt

    private func buildSystemPrompt(sourceApp: String?, ocrContent: String, dsaMode: Bool = false) -> String {
        let framework = ExplanationFramework.detect(fromContent: ocrContent)

        var prompt = """
            You are Decode, a code explanation tool for macOS. The user captured a screenshot \
            and the text was extracted via OCR.

            The OCR text may contain formatting artifacts, line numbers, UI chrome text, or \
            partial code. Focus on the code or technical content and ignore noise.
            """

        prompt += framework.styleInstructions(dsaMode: dsaMode)

        if let app = sourceApp {
            prompt += "\n\nThe screenshot was taken from \(app)."
        }

        prompt += Self.visualContextGuidance

        return prompt
    }

    /// System prompt guidance for using visual context evidence.
    /// Appended unconditionally — a no-op when the user message has no [Context] block.
    private static let visualContextGuidance = """

        If a [Context]...[/Context] block is present in the user's message, it contains \
        trusted contextual evidence extracted from the user's visible working environment. \
        Use this evidence only when it is relevant to improve the explanation. \
        Do not assume it is complete, and do not repeat it verbatim unless necessary.
        """
}
