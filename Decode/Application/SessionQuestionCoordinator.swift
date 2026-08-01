import AppKit
import Foundation
import ConsumerRuntime

/// Orchestrates the Workspace Question flow: hotkey → capture → resolve workspace → context → AI → HUD.
///
/// Follows the same coordinator pattern as ``SelectionModeCoordinator``.
/// When the user presses double-tap Shift, this coordinator:
///
/// 1. Checks that an AI provider is configured
/// 2. Checks that at least one workspace exists
/// 3. Captures the selected text from the source app
/// 4. **Automatically resolves** which workspace the snippet belongs to
/// 5. Assembles workspace context (file content + entity signatures)
/// 6. Builds an enriched system prompt via ``ContextBuilderService``
/// 7. Streams the AI response to the floating HUD
///
/// ## Workspace Resolution
/// The coordinator uses ``WorkspaceResolver`` to automatically match the
/// captured snippet to the best workspace. Resolution strategy:
/// - Pinned workspace → unconditional override
/// - Single workspace → trivial match
/// - Multiple workspaces → score by entity containment, file content, recency
/// - Low confidence → fall back to the manually active workspace
@MainActor
final class SessionQuestionCoordinator {

    // MARK: - Dependencies

    private let selectionCapture: any SelectionCaptureProtocol
    private let aiProvider: @MainActor () -> (any AIProviderProtocol)?
    private let hud: FloatingExplanationHUD
    private let toastManager: DecodeToastManager
    private let contextBuilder: ContextBuilderService
    private let workspaceResolver: WorkspaceResolver
    private let snippetHealthClassifier: SnippetHealthClassifier
    private let workspaceProvider: @MainActor () -> WorkspaceResolverInput?
    private let usageTracker: AIUsageTracker
    private let semanticEnrichment: SemanticEnrichmentService
    private let knowledgeArtifactStore: KnowledgeArtifactStore?
    private let pipelineQueryService: PipelineQueryService?
    private let virtualSessionManager: VirtualSessionManager

    // MARK: - State

    private var listeningTask: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0
    private var activeRequestTask: Task<Void, Never>?

    // MARK: - Init

    /// - Parameters:
    ///   - selectionCapture: Accessibility-based text capture service.
    ///   - aiProvider: Closure returning the current AI provider, or nil.
    ///   - hud: The floating explanation panel for displaying results.
    ///   - contextBuilder: Assembles workspace context into prompts.
    ///   - workspaceResolver: Automatic workspace matching service.
    ///   - snippetHealthClassifier: Confidence-based code health analyzer.
    ///   - workspaceProvider: Closure returning all open workspaces + active/pinned IDs.
    ///     Queried on each hotkey press.
    ///   - usageTracker: Shared quota tracker for AI request limits.
    init(
        selectionCapture: any SelectionCaptureProtocol,
        aiProvider: @escaping @MainActor () -> (any AIProviderProtocol)?,
        hud: FloatingExplanationHUD,
        toastManager: DecodeToastManager,
        contextBuilder: ContextBuilderService = ContextBuilderService(),
        workspaceResolver: WorkspaceResolver = WorkspaceResolver(),
        snippetHealthClassifier: SnippetHealthClassifier = SnippetHealthClassifier(),
        workspaceProvider: @escaping @MainActor () -> WorkspaceResolverInput?,
        usageTracker: AIUsageTracker,
        semanticEnrichment: SemanticEnrichmentService,
        knowledgeArtifactStore: KnowledgeArtifactStore? = nil,
        pipelineQueryService: PipelineQueryService? = nil,
        virtualSessionManager: VirtualSessionManager
    ) {
        self.selectionCapture = selectionCapture
        self.aiProvider = aiProvider
        self.hud = hud
        self.toastManager = toastManager
        self.contextBuilder = contextBuilder
        self.workspaceResolver = workspaceResolver
        self.snippetHealthClassifier = snippetHealthClassifier
        self.workspaceProvider = workspaceProvider
        self.usageTracker = usageTracker
        self.semanticEnrichment = semanticEnrichment
        self.knowledgeArtifactStore = knowledgeArtifactStore
        self.pipelineQueryService = pipelineQueryService
        self.virtualSessionManager = virtualSessionManager
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
                case .explainSelection, .captureScreenshot, .openSession, .openWorkspace:
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

    // MARK: - Workspace Question Flow

    private func handleSessionQuestion(event: HotkeyEvent, generation: UInt64) async {
        // 1. Check AI provider.
        guard let provider = aiProvider() else {
            toastManager.show("Connecting to Decode Gateway. Please wait a moment and try again.", icon: "wifi.slash")
            return
        }

        // 2. Check that workspaces exist.
        guard let resolverInput = workspaceProvider() else {
            toastManager.show("No active workspace. Open a file in Session Mode first.", icon: "doc.badge.plus")
            return
        }
        guard !resolverInput.workspaces.isEmpty else {
            toastManager.show("No active workspace. Open a file in Session Mode first.", icon: "doc.badge.plus")
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

        // 4. Capture selected text (BEFORE workspace resolution).
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

        // 6. Workspace resolution.
        let resolution = workspaceResolver.resolve(
            snippet: snippetText,
            workspaces: resolverInput.workspaces,
            pinnedWorkspaceId: resolverInput.pinnedWorkspaceId,
            activeWorkspaceId: resolverInput.activeWorkspaceId
        )

        guard let managed = resolution.workspace else {
            toastManager.show("No active workspace. Open a file in Session Mode first.", icon: "doc.badge.plus")
            return
        }

        // For .directory workspaces, use the resolved file path if available.
        // Otherwise fall back to the workspace's root path (for .file workspaces).
        let effectiveFilePath = resolution.resolvedFilePath ?? managed.workspace.rootPath
        let effectiveFileName = (effectiveFilePath as NSString).lastPathComponent
        let effectiveEntities: [ParsedEntity]
        if let resolvedPath = resolution.resolvedFilePath,
           managed.workspace.kind == .directory {
            effectiveEntities = managed.parsedEntitiesByFile[resolvedPath] ?? managed.parsedEntities
        } else {
            effectiveEntities = managed.parsedEntities
        }

        #if DEBUG
        print("[SessionQuestion] Resolved workspace: \(effectiveFileName) (method=\(resolution.method), confidence=\(resolution.confidence), file=\(effectiveFileName))")
        #endif

        // 6b. Pipeline path: attempt the Software Intelligence Platform first.
        //     If the pipeline produces an Understanding, render it and return.
        //     If it cannot (no evidence, assembly failure, consumer failure),
        //     fall through to the legacy path below.
        if let pipelineQueryService {
            let pipelineResult = await attemptPipelineExplain(
                filePath: effectiveFilePath,
                snippetText: snippetText,
                parsedEntities: effectiveEntities,
                sourceAppName: sourceAppName,
                provider: provider,
                managed: managed,
                generation: generation
            )

            if pipelineResult {
                // Pipeline succeeded — Understanding rendered to HUD.
                return
            }

            #if DEBUG
            print("[SessionQuestion] Pipeline returned no result — falling back to legacy path")
            #endif
        }

        // 7. Build snippet-anchored context.
        guard let context = contextBuilder.buildContext(
            fileId: managed.workspace.id,
            filePath: effectiveFilePath,
            fileName: effectiveFileName,
            parsedEntities: effectiveEntities,
            snippet: snippetText
        ) else {
            toastManager.show("Could not read file: \(effectiveFileName)", icon: "doc.questionmark")
            return
        }

        // 8. Code Health: classify snippet confidence tier.
        let healthClassification: HealthClassification
        if let grammar = GrammarRegistration.from(fileName: effectiveFileName) {
            let fullFileSource = try? String(
                contentsOf: URL(fileURLWithPath: effectiveFilePath),
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

        // 9. Semantic enrichment: artifact store → reactive fallback.
        // Runs before the quota check — enrichment is infrastructure,
        // not a user-visible request.
        var enrichedPurpose: String? = nil
        var enrichedBehavior: String? = nil
        var enrichedSafety: String? = nil
        var enrichedDesign: String? = nil
        var enrichmentCacheHit = false

        // Resolve the effective FileIntelligence. For directory workspaces,
        // use per-file intelligence if available.
        let effectiveIntelligence: FileIntelligence? = {
            if managed.workspace.kind == .directory,
               let resolvedPath = resolution.resolvedFilePath {
                return managed.fileIntelligenceByFile[resolvedPath] ?? managed.fileIntelligence
            }
            return managed.fileIntelligence
        }()

        if let intelligence = effectiveIntelligence {
            // Primary path: check KnowledgeArtifactStore for proactively
            // generated File Understanding.
            if let store = knowledgeArtifactStore,
               let artifact = store.lookup(
                   jobIdentifier: FileUnderstandingJob.identifier,
                   filePath: effectiveFilePath,
                   contentHash: intelligence.fileHash
               ),
               let cachedEnrichment = FileUnderstandingJob.decodeEnrichment(from: artifact.data) {
                enrichedPurpose = cachedEnrichment.purpose
                enrichedBehavior = cachedEnrichment.behavior
                enrichedSafety = cachedEnrichment.safety
                enrichedDesign = cachedEnrichment.design
                enrichmentCacheHit = true

                // Write enrichment back to ManagedWorkspace for Knowledge Inspector.
                if managed.workspace.kind == .file {
                    managed.fileIntelligence?.semanticEnrichment = cachedEnrichment
                }
            } else {
                // Fallback path: KGR has not yet generated the artifact.
                // Call SemanticEnrichmentService directly (reactive, no caching).
                let enrichment = await semanticEnrichment.enrich(intelligence: intelligence)
                // Staleness check after enrichment await.
                guard generation == requestGeneration else { return }
                enrichedPurpose = enrichment?.purpose
                enrichedBehavior = enrichment?.behavior
                enrichedSafety = enrichment?.safety
                enrichedDesign = enrichment?.design

                // Write enrichment back to ManagedWorkspace for Knowledge Inspector.
                if let enrichment, managed.workspace.kind == .file {
                    managed.fileIntelligence?.semanticEnrichment = enrichment
                }
            }
        }

        // 9b. Question-aware context selection.
        // Select which understanding layers to include based on the
        // snippet content and file role. Layers not selected are omitted
        // from the prompt to reduce token usage and improve focus.
        let layerSelection = selectContextLayers(
            snippet: snippetText,
            fileRole: effectiveIntelligence?.identity.role
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
        let containingEntityType = effectiveEntities
            .filter { $0.sourceText.contains(snippetText) }
            .min(by: { $0.sourceText.count < $1.sourceText.count })?
            .entity.entityType
        let framework = ExplanationFramework.select(
            fileName: effectiveFileName,
            codeSnippet: snippetText
        )
        systemPrompt += RepresentationGuidance.guidance(
            snippet: snippetText,
            framework: framework,
            containingEntityType: containingEntityType
        )

        // Virtual Session: build full InsightContext from file intelligence.
        let insightContext = buildInsightContext(
            filePath: effectiveFilePath,
            fileName: effectiveFileName,
            entities: effectiveEntities,
            snippet: snippetText,
            intelligence: managed.fileIntelligence,
            sourceApp: sourceAppName,
            workspaceID: managed.workspace.id
        )

        // Virtual Session: inject working memory into system prompt.
        if virtualSessionManager.isEnabled,
           let wmBlock = virtualSessionManager.workingMemoryBlock() {
            systemPrompt += "\n\n\(wmBlock)"
        }

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
        print("[SessionAnalytics] tier=\(contextTier) promptChars=\(systemPrompt.count + userMessage.count) workspace=\(effectiveFileName)")
        #endif

        // Store question context for Knowledge Inspector.
        managed.lastQuestionContext = QuestionContext(
            contextTier: contextTier,
            includedBehavior: layerSelection.includeBehavior,
            includedSafety: layerSelection.includeSafety,
            includedDesign: layerSelection.includeDesign,
            healthTier: healthClassification.tier.rawValue,
            healthHintCount: healthClassification.hints.count,
            promptCharacterCount: systemPrompt.count + userMessage.count,
            enrichmentCacheHit: enrichmentCacheHit,
            timestamp: Date()
        )

        // Resolve language from file extension for analytics.
        let fileExt = (effectiveFileName as NSString).pathExtension.lowercased()
        let language: String? = if let profile = LanguageProfile.from(fileName: effectiveFileName) {
            profile.displayName
        } else if fileExt == "swift" {
            "Swift"
        } else {
            nil
        }

        // Show HUD immediately so the user sees loading state while
        // the AI request is in flight.
        hud.showLoading(sourceApp: sourceAppName, mode: "session", sessionFile: effectiveFileName, explanationProfile: explanationProfile)

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
                sessionContext: context,
                pipelineQueryService: nil,
                pipelineConversationState: nil,
                pipelineFilePath: nil,
                pipelineEntityName: nil
            )

            // Virtual Session: record insight on stream completion.
            let vsManager = virtualSessionManager
            let capturedInsightContext = insightContext
            hud.showStream(stream, sourceApp: sourceAppName, followUpContext: followUpCtx) { explanationText in
                guard vsManager.isEnabled else { return }
                let understanding = VirtualSessionManager.extractUnderstanding(
                    from: explanationText,
                    sourceApp: sourceAppName
                )
                vsManager.recordInsight(
                    understanding: understanding,
                    mode: .session,
                    context: capturedInsightContext
                )
            }
        } catch {
            guard generation == requestGeneration else { return }
            hud.showError("AI request failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Pipeline Execution Path

    /// Attempts to produce an explanation via the Software Intelligence Platform.
    ///
    /// Returns `true` if the pipeline produced a usable Understanding that was
    /// rendered to the HUD. Returns `false` if the pipeline could not produce
    /// an Understanding (no evidence, assembly failure, consumer failure),
    /// signaling the caller to fall back to the legacy path.
    private func attemptPipelineExplain(
        filePath: String,
        snippetText: String,
        parsedEntities: [ParsedEntity],
        sourceAppName: String?,
        provider: any AIProviderProtocol,
        managed: ManagedWorkspace,
        generation: UInt64
    ) async -> Bool {
        // Find the smallest entity whose source contains the snippet.
        let containingEntity = parsedEntities
            .filter { $0.sourceText.contains(snippetText) }
            .min(by: { $0.sourceText.count < $1.sourceText.count })

        // If no entity contains the snippet, the pipeline cannot resolve
        // an anchor — fall back to the legacy path.
        guard let entity = containingEntity else {
            #if DEBUG
            print("[SessionQuestion] Pipeline: no containing entity found for snippet")
            #endif
            return false
        }

        // Build the qualified entity name matching FrontendOutputConversion's
        // naming convention: "ParentType.ChildName" for nested entities,
        // "Name" for top-level.
        let entityName: String
        if let parentStableId = entity.parentStableId,
           let parent = parsedEntities.first(where: { $0.entity.stableId == parentStableId }) {
            entityName = "\(parent.entity.name).\(entity.entity.name)"
        } else {
            entityName = entity.entity.name
        }

        let explanationProfile = UserDefaults.standard.bool(forKey: "dsaModeEnabled") ? "dsa" : "general"

        let pipelineFileName = (filePath as NSString).lastPathComponent

        // Show loading state immediately.
        hud.showLoading(
            sourceApp: sourceAppName,
            mode: "session",
            sessionFile: pipelineFileName,
            explanationProfile: explanationProfile
        )

        // Execute the pipeline query off the main thread.
        let queryService = pipelineQueryService!
        let result = await Task.detached {
            await queryService.query(
                filePath: filePath,
                entityName: entityName,
                purpose: "explain"
            )
        }.value

        // Staleness check after pipeline await.
        guard generation == requestGeneration else {
            #if DEBUG
            print("[SessionQuestion] Pipeline: request superseded (gen=\(generation), current=\(requestGeneration))")
            #endif
            return true // Consumed the request — don't fall back.
        }

        guard case .success(let understanding) = result else {
            #if DEBUG
            print("[SessionQuestion] Pipeline: non-success result — \(result)")
            #endif
            return false
        }

        // Check quota before delivering the result.
        guard usageTracker.tryConsumeRequest() else {
            toastManager.show(usageTracker.quotaExhaustedMessage, icon: "gauge.with.dots.needle.67percent")
            return true // Consumed the request — don't fall back.
        }

        // Resolve language for analytics.
        let fileExt = (pipelineFileName as NSString).pathExtension.lowercased()
        let language: String? = if let profile = LanguageProfile.from(fileName: pipelineFileName) {
            profile.displayName
        } else if fileExt == "swift" {
            "Swift"
        } else {
            nil
        }

        // Wrap Understanding.content in a single-element stream for the HUD.
        let content = understanding.content
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield(content)
            continuation.finish()
        }

        // Build follow-up context for the HUD (enables pipeline-based follow-up).
        // Stores the ConversationState from the initial Understanding so follow-up
        // questions route through the pipeline with conversation continuity.
        let followUpCtx = ExplanationHUDViewModel.FollowUpContext(
            sourceContent: "Explain this code:\n\n\(snippetText)",
            systemPrompt: "", // Not used by pipeline path — placeholder for legacy fallback.
            mode: "session",
            aiProvider: provider,
            usageTracker: usageTracker,
            originalCode: snippetText,
            explanationProfile: explanationProfile,
            language: language,
            sessionContext: nil, // Pipeline-based context — no legacy SessionContext.
            pipelineQueryService: pipelineQueryService,
            pipelineConversationState: understanding.conversationState,
            pipelineFilePath: filePath,
            pipelineEntityName: entityName
        )

        // Virtual Session: record insight on pipeline stream completion.
        let pipelineInsightContext = buildInsightContext(
            filePath: filePath,
            fileName: pipelineFileName,
            entities: parsedEntities,
            snippet: snippetText,
            intelligence: managed.fileIntelligence,
            sourceApp: sourceAppName,
            workspaceID: managed.workspace.id
        )
        let vsManager = virtualSessionManager
        let capturedPipelineContext = pipelineInsightContext
        hud.showStream(stream, sourceApp: sourceAppName, followUpContext: followUpCtx) { explanationText in
            guard vsManager.isEnabled else { return }
            let understanding = VirtualSessionManager.extractUnderstanding(
                from: explanationText,
                sourceApp: sourceAppName
            )
            vsManager.recordInsight(
                understanding: understanding,
                mode: .session,
                context: capturedPipelineContext
            )
        }

        #if DEBUG
        print("[SessionQuestion] Pipeline: Understanding delivered — engine=\(understanding.metadata.engineIdentifier), completeness=\(understanding.metadata.completeness)")
        #endif

        return true
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

    // MARK: - Virtual Session: InsightContext Construction

    /// Builds a full InsightContext from file intelligence and workspace resolution data.
    private func buildInsightContext(
        filePath: String,
        fileName: String,
        entities: [ParsedEntity],
        snippet: String,
        intelligence: FileIntelligence?,
        sourceApp: String?,
        workspaceID: UUID
    ) -> InsightContext {
        // Find the smallest containing entity for the snippet.
        let containingEntity = entities
            .filter { $0.sourceText.contains(snippet) }
            .min(by: { $0.sourceText.count < $1.sourceText.count })

        // Build entity name (qualified if nested).
        let entityName: String?
        if let entity = containingEntity {
            if let parentStableId = entity.parentStableId,
               let parent = entities.first(where: { $0.entity.stableId == parentStableId }) {
                entityName = "\(parent.entity.name).\(entity.entity.name)"
            } else {
                entityName = entity.entity.name
            }
        } else {
            entityName = nil
        }

        // Derive module name from directory path.
        let moduleName: String? = {
            let components = filePath.components(separatedBy: "/")
            // Look for known layer directory names in the path.
            let layerDirs = ["Application", "Domain", "Infrastructure", "Presentation", "App", "Understanding"]
            for dir in layerDirs where components.contains(dir) {
                return dir
            }
            return nil
        }()

        // Collect related entities from relationships.
        let relatedEntities: [String]
        if let intelligence {
            relatedEntities = intelligence.relationships
                .compactMap { rel -> String? in
                    // Include call targets and conformance/inheritance targets.
                    return rel.targetName
                }
        } else {
            relatedEntities = []
        }

        return InsightContext(
            filePath: filePath,
            fileName: fileName,
            entityName: entityName,
            entityType: containingEntity?.entity.entityType.rawValue,
            moduleName: moduleName,
            layer: intelligence?.identity.layer.rawValue,
            fileRole: intelligence?.identity.role.rawValue,
            language: intelligence?.language,
            sourceApp: sourceApp,
            workspaceID: workspaceID,
            relatedEntities: relatedEntities
        )
    }
}
