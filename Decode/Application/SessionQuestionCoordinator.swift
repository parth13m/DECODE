import AppKit
import Foundation

/// Orchestrates the Session Question flow: hotkey → capture → resolve session → context → AI → HUD.
///
/// Follows the same coordinator pattern as ``SelectionModeCoordinator``.
/// When the user presses double-tap Shift, this coordinator:
///
/// 1. Checks that an AI provider is configured
/// 2. Checks that at least one session exists
/// 3. Captures the selected text from the source app
/// 4. **Automatically resolves** which session the snippet belongs to
/// 5. Assembles session context (file content + entity signatures)
/// 6. Builds an enriched system prompt via ``ContextBuilderService``
/// 7. Streams the AI response to the floating HUD
///
/// ## Session Resolution
/// The coordinator uses ``SessionResolver`` to automatically match the
/// captured snippet to the best session. Resolution strategy:
/// - Pinned session → unconditional override
/// - Single session → trivial match
/// - Multiple sessions → score by entity containment, file content, recency
/// - Low confidence → fall back to the manually active session
@MainActor
final class SessionQuestionCoordinator {

    // MARK: - Dependencies

    private let selectionCapture: any SelectionCaptureProtocol
    private let aiProvider: @MainActor () -> (any AIProviderProtocol)?
    private let hud: FloatingExplanationHUD
    private let toastManager: DecodeToastManager
    private let contextBuilder: ContextBuilderService
    private let sessionResolver: SessionResolver
    private let snippetHealthClassifier: SnippetHealthClassifier
    private let sessionProvider: @MainActor () -> SessionResolverInput?
    private let usageTracker: AIUsageTracker
    private let semanticEnrichment: SemanticEnrichmentService

    // MARK: - State

    private var listeningTask: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0
    private var activeRequestTask: Task<Void, Never>?

    // MARK: - Init

    /// - Parameters:
    ///   - selectionCapture: Accessibility-based text capture service.
    ///   - aiProvider: Closure returning the current AI provider, or nil.
    ///   - hud: The floating explanation panel for displaying results.
    ///   - contextBuilder: Assembles session context into prompts.
    ///   - sessionResolver: Automatic session matching service.
    ///   - snippetHealthClassifier: Confidence-based code health analyzer.
    ///   - sessionProvider: Closure returning all open sessions + active/pinned IDs.
    ///     Queried on each hotkey press.
    ///   - usageTracker: Shared quota tracker for AI request limits.
    init(
        selectionCapture: any SelectionCaptureProtocol,
        aiProvider: @escaping @MainActor () -> (any AIProviderProtocol)?,
        hud: FloatingExplanationHUD,
        toastManager: DecodeToastManager,
        contextBuilder: ContextBuilderService = ContextBuilderService(),
        sessionResolver: SessionResolver = SessionResolver(),
        snippetHealthClassifier: SnippetHealthClassifier = SnippetHealthClassifier(),
        sessionProvider: @escaping @MainActor () -> SessionResolverInput?,
        usageTracker: AIUsageTracker,
        semanticEnrichment: SemanticEnrichmentService
    ) {
        self.selectionCapture = selectionCapture
        self.aiProvider = aiProvider
        self.hud = hud
        self.toastManager = toastManager
        self.contextBuilder = contextBuilder
        self.sessionResolver = sessionResolver
        self.snippetHealthClassifier = snippetHealthClassifier
        self.sessionProvider = sessionProvider
        self.usageTracker = usageTracker
        self.semanticEnrichment = semanticEnrichment
    }

    // MARK: - Lifecycle

    func startListening(hotkeyStream: AsyncStream<HotkeyEvent>) {
        stopListening()

        listeningTask = Task {
            for await event in hotkeyStream {
                if Task.isCancelled { break }

                switch event.action {
                case .askSessionQuestion:
                    requestGeneration += 1
                    activeRequestTask?.cancel()
                    let generation = requestGeneration
                    activeRequestTask = Task {
                        await handleSessionQuestion(event: event, generation: generation)
                    }
                case .explainSelection, .captureScreenshot, .openSession:
                    break
                }
            }
        }
    }

    func stopListening() {
        listeningTask?.cancel()
        listeningTask = nil
        activeRequestTask?.cancel()
        activeRequestTask = nil
    }

    // MARK: - Session Question Flow

    private func handleSessionQuestion(event: HotkeyEvent, generation: UInt64) async {
        // 1. Check AI provider.
        guard let provider = aiProvider() else {
            toastManager.show("Connecting to Decode Gateway. Please wait a moment and try again.", icon: "wifi.slash")
            return
        }

        // 2. Check that sessions exist.
        guard let resolverInput = sessionProvider() else {
            toastManager.show("No active session. Open a file in Session Mode first.", icon: "doc.badge.plus")
            return
        }

        // 3. Check Accessibility permission.
        guard selectionCapture.hasAccessibilityPermission() else {
            selectionCapture.requestAccessibilityPermission()
            toastManager.show(
                "Accessibility permission required. Grant access in System Settings, then restart Decode.",
                icon: "lock.shield"
            )
            return
        }

        // 4. Capture selected text (BEFORE session resolution).
        guard let sourceAppPID = event.sourceAppPID else {
            toastManager.show("Could not identify the source application.", icon: "exclamationmark.triangle")
            return
        }

        let captureResult: SelectionCaptureResult?
        do {
            captureResult = try await selectionCapture.captureSelection(fromPID: sourceAppPID)
        } catch {
            guard generation == requestGeneration else { return }
            toastManager.show("Failed to capture selection: \(error.localizedDescription)", icon: "exclamationmark.triangle")
            return
        }

        // Staleness check after capture await.
        guard generation == requestGeneration else {
            #if DEBUG
            print("[SessionQuestion] request superseded after capture (gen=\(generation), current=\(requestGeneration))")
            #endif
            return
        }

        guard let result = captureResult else {
            toastManager.show("No code selected. Highlight code in your editor and try again.", icon: "text.cursor")
            return
        }

        // 4b. Reject whitespace-only selections.
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            toastManager.show("No code selected. Highlight code in your editor and try again.", icon: "text.cursor")
            return
        }

        let sourceAppName = event.sourceAppName ?? result.sourceApplicationName

        // 5. Truncate if over input limit.
        var snippetText = result.text
        if snippetText.count > AILimits.maxSelectedTextCharacters {
            snippetText = String(snippetText.prefix(AILimits.maxSelectedTextCharacters))
                + "\n[Truncated to \(AILimits.maxSelectedTextCharacters) characters]"
        }

        // 6. Resolve session automatically.
        let resolution = sessionResolver.resolve(
            snippet: snippetText,
            sessions: resolverInput.sessions,
            pinnedSessionId: resolverInput.pinnedSessionId,
            activeSessionId: resolverInput.activeSessionId
        )

        guard let managed = resolution.session else {
            toastManager.show("No active session. Open a file in Session Mode first.", icon: "doc.badge.plus")
            return
        }

        #if DEBUG
        print("[SessionQuestion] Resolved session: \(managed.session.fileName) (method=\(resolution.method), confidence=\(resolution.confidence))")
        #endif

        // 7. Build snippet-anchored session context.
        let snapshot = ActiveSessionSnapshot(
            session: managed.session,
            parsedEntities: managed.parsedEntities
        )

        guard let context = contextBuilder.buildContext(
            session: snapshot.session,
            parsedEntities: snapshot.parsedEntities,
            snippet: snippetText
        ) else {
            toastManager.show("Could not read session file: \(snapshot.session.fileName)", icon: "doc.questionmark")
            return
        }

        // 8. Code Health: classify snippet confidence tier.
        let healthClassification: HealthClassification
        if let grammar = GrammarRegistration.from(fileName: managed.session.fileName) {
            let fullFileSource = try? String(
                contentsOf: URL(fileURLWithPath: managed.session.filePath),
                encoding: .utf8
            )
            healthClassification = snippetHealthClassifier.classify(
                snippet: snippetText,
                language: grammar,
                fullFileSource: fullFileSource
            )
            #if DEBUG
            if healthClassification.tier != .silent {
                print("[SessionQuestion] Code Health: tier=\(healthClassification.tier.rawValue), hints=\(healthClassification.hints.count)")
            }
            #endif
        } else {
            // Swift files or unsupported languages — no tree-sitter health analysis.
            healthClassification = HealthClassification(tier: .silent, hints: [])
        }

        // 9. Semantic enrichment (lazy, cached).
        // Runs before the quota check — enrichment is infrastructure,
        // not a user-visible request. Cache hits are instantaneous.
        var enrichedPurpose: String? = nil
        var enrichedBehavior: String? = nil
        var enrichedSafety: String? = nil
        var enrichedDesign: String? = nil
        if let intelligence = managed.fileIntelligence {
            let enrichment = await semanticEnrichment.enrich(intelligence: intelligence)
            // Staleness check after enrichment await.
            guard generation == requestGeneration else { return }
            enrichedPurpose = enrichment?.purpose
            enrichedBehavior = enrichment?.behavior
            enrichedSafety = enrichment?.safety
            enrichedDesign = enrichment?.design
        }

        // 9b. Question-aware context selection.
        // Select which understanding layers to include based on the
        // snippet content and file role. Layers not selected are omitted
        // from the prompt to reduce token usage and improve focus.
        let layerSelection = selectContextLayers(
            snippet: snippetText,
            fileRole: managed.fileIntelligence?.identity.role
        )
        if !layerSelection.includeBehavior { enrichedBehavior = nil }
        if !layerSelection.includeSafety { enrichedSafety = nil }
        if !layerSelection.includeDesign { enrichedDesign = nil }

        // 10. Check quota before making the AI request.
        guard usageTracker.tryConsumeRequest() else {
            toastManager.show(usageTracker.quotaExhaustedMessage, icon: "gauge.with.dots.needle.67percent")
            return
        }

        // 11. Build prompt and stream response.
        let dsaMode = UserDefaults.standard.bool(forKey: "dsaModeEnabled")
        let explanationProfile = dsaMode ? "dsa" : "general"
        // Prefer semantic purpose over deterministic purpose.
        let filePurpose = enrichedPurpose ?? managed.fileIntelligence?.purpose
        var systemPrompt = contextBuilder.buildSystemPrompt(
            context: context,
            sourceApp: sourceAppName,
            snippet: snippetText,
            dsaMode: dsaMode,
            fileIdentity: managed.fileIntelligence?.identity,
            filePurpose: filePurpose,
            fileBehavior: enrichedBehavior,
            fileSafety: enrichedSafety,
            fileDesign: enrichedDesign,
            fileImports: managed.fileIntelligence?.imports
        )
        systemPrompt += ExplanationFramework.healthPromptAugmentation(
            tier: healthClassification.tier,
            hints: healthClassification.hints
        )

        // 10b. ARE: representation guidance.
        let containingEntityType = snapshot.parsedEntities
            .filter { $0.sourceText.contains(snippetText) }
            .min(by: { $0.sourceText.count < $1.sourceText.count })?
            .entity.entityType
        let framework = ExplanationFramework.select(
            fileName: managed.session.fileName,
            codeSnippet: snippetText
        )
        systemPrompt += RepresentationGuidance.guidance(
            snippet: snippetText,
            framework: framework,
            containingEntityType: containingEntityType
        )

        // When the system prompt already contains source code (Tier 1, 2, 2.5),
        // avoid sending the snippet again in the user message — the outline's
        // ← selected marker identifies the code. Tier 3 has no source in the
        // prompt, so the full snippet must be in the user message.
        let userMessage: String
        if context.hasSourceInContext {
            userMessage = "Explain the selected code."
        } else {
            userMessage = "Explain this code:\n\n\(snippetText)"
        }
        let messages = [AIMessage(role: .user, content: userMessage)]

        // Analytics: derive context tier for server-side tracking.
        let contextTier = context.contextTier

        #if DEBUG
        print("[SessionAnalytics] tier=\(contextTier) promptChars=\(systemPrompt.count + userMessage.count) session=\(managed.session.fileName)")
        #endif

        // Resolve language from file extension for analytics.
        let fileExt = (managed.session.fileName as NSString).pathExtension.lowercased()
        let language: String? = if let profile = LanguageProfile.from(fileName: managed.session.fileName) {
            profile.displayName
        } else if fileExt == "swift" {
            "Swift"
        } else {
            nil
        }

        // Show HUD immediately so the user sees loading state while
        // the AI request is in flight.
        hud.showLoading(sourceApp: sourceAppName, mode: "session", sessionFile: managed.session.fileName, explanationProfile: explanationProfile)

        do {
            let stream = try await provider.streamChat(
                messages: messages,
                systemPrompt: systemPrompt,
                mode: "session",
                contextTier: contextTier,
                explanationProfile: explanationProfile,
                language: language
            )

            // Staleness check after streamChat await.
            guard generation == requestGeneration else {
                #if DEBUG
                print("[SessionQuestion] request superseded after streamChat (gen=\(generation), current=\(requestGeneration))")
                #endif
                return
            }

            // Follow-up context always stores the full snippet so the 3-message
            // follow-up conversation has the original code available.
            let followUpCtx = ExplanationHUDViewModel.FollowUpContext(
                sourceContent: "Explain this code:\n\n\(snippetText)",
                systemPrompt: systemPrompt,
                mode: "session",
                aiProvider: provider,
                usageTracker: usageTracker,
                originalCode: snippetText,
                explanationProfile: explanationProfile,
                language: language,
                sessionContext: context
            )
            hud.showStream(stream, sourceApp: sourceAppName, followUpContext: followUpCtx)
        } catch {
            guard generation == requestGeneration else { return }
            hud.showError("AI request failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Context Layer Selection

    private struct LayerSelection {
        let includeBehavior: Bool
        let includeSafety: Bool
        let includeDesign: Bool

        static let all = LayerSelection(
            includeBehavior: true,
            includeSafety: true,
            includeDesign: true
        )
    }

    /// Select which understanding layers to include based on snippet
    /// content and file role. Purpose is always included.
    private func selectContextLayers(
        snippet: String,
        fileRole: FileRole?
    ) -> LayerSelection {
        let snippetLower = snippet.lowercased()

        var includeBehavior = false
        var includeSafety = false
        var includeDesign = false

        // Error handling patterns → Safety.
        if containsAny(snippetLower, keywords: [
            "catch", "throw", "throws", "try ", "try?", "try!",
            "guard ", "precondition", "assert", "fatalError",
            "do {", "rescue", "except", "finally",
            "Result<", "Result.", ".failure", ".success",
            "Error", "error", "Exception",
        ]) {
            includeSafety = true
        }

        // Concurrency patterns → Safety + Behavior.
        if containsAny(snippetLower, keywords: [
            "async", "await", "task {", "task.detached",
            "dispatchqueue", "operationqueue",
            "@sendable", "actor ", "nonisolated",
            "lock", "mutex", "semaphore", "atomic",
            "thread", "concurrent",
            "promise", "future", "completionhandler",
        ]) {
            includeSafety = true
            includeBehavior = true
        }

        // State and control flow patterns → Behavior.
        if containsAny(snippetLower, keywords: [
            "switch ", "case .", "case let",
            "for ", "while ", "repeat {",
            "state", "transition", "didset", "willset",
            "@published", "@state", "@binding", "@observable",
            "notificationcenter", ".addobserver", ".post(",
            "delegate", "datasource",
            "timer", "schedule", "dispatch_after",
        ]) {
            includeBehavior = true
        }

        // Design patterns → Design.
        if containsAny(snippetLower, keywords: [
            "protocol ", "extension ", "associatedtype",
            "class ", "struct ", "enum ",
            "init(", "deinit",
            "factory", "builder", "singleton", "shared",
            "override ", "open ", "final ",
            "private ", "internal ", "public ", "fileprivate",
            "typealias", "generic", "where ",
            "import ", "dependency", "inject",
        ]) {
            includeDesign = true
        }

        // File role signals.
        if let role = fileRole {
            switch role {
            case .coordinator, .manager, .service:
                includeBehavior = true
                includeDesign = true
            case .model, .protocolDefinition:
                includeDesign = true
            case .view, .viewModel:
                includeBehavior = true
            case .parser:
                includeBehavior = true
            case .test:
                includeBehavior = true
            case .extensionFile, .configuration, .appEntry, .unknown:
                break
            }
        }

        // If no signals detected, include all layers.
        if !includeBehavior && !includeSafety && !includeDesign {
            return .all
        }

        return LayerSelection(
            includeBehavior: includeBehavior,
            includeSafety: includeSafety,
            includeDesign: includeDesign
        )
    }

    private func containsAny(_ text: String, keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
}

// MARK: - Active Session Snapshot

/// A point-in-time snapshot of the active session's state.
///
/// Provided by ``SessionViewModel`` via a closure so the coordinator
/// doesn't take a direct dependency on the view model.
struct ActiveSessionSnapshot: Sendable {
    let session: Session
    let parsedEntities: [ParsedEntity]
}

// MARK: - Session Resolver Input

/// All data the ``SessionResolver`` needs to resolve a session.
///
/// Provided by a closure from ``AppDependencies`` so the coordinator
/// doesn't take a direct dependency on ``SessionManager``.
/// Used exclusively on `@MainActor` — not `Sendable` because it holds
/// references to `ManagedSession`.
struct SessionResolverInput {
    let sessions: [UUID: ManagedSession]
    let activeSessionId: UUID?
    let pinnedSessionId: UUID?
}
