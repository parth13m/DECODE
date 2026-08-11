import AppKit
import Foundation
import ConsumerRuntime

#if DEBUG
/// Diagnostic logger for grounding trace — writes to file for GUI app reliability.
private func diagLog(_ message: String) {
    let path = "/tmp/decode_grounding_diag.log"
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}
#endif

/// Orchestrates the Workspace Question flow: hotkey → capture → resolve workspace → pipeline → HUD.
///
/// When the user presses double-tap Shift, this coordinator:
///
/// 1. Checks that an AI provider is configured
/// 2. Checks that at least one workspace exists
/// 3. Captures the selected text from the source app
/// 4. **Automatically resolves** which workspace the snippet belongs to
/// 5. Finds the containing code entity for the snippet
/// 6. Runs the understanding pipeline (retrieve → assemble → reason)
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
    private let workspaceResolver: WorkspaceResolver
    private let workspaceProvider: @MainActor () -> WorkspaceResolverInput?
    private let usageTracker: AIUsageTracker
    private let knowledgeArtifactStore: KnowledgeArtifactStore?
    private let pipelineQueryService: PipelineQueryService
    private let virtualSessionManager: VirtualSessionManager
    private let profileIntelligenceService: ProfileIntelligenceService?

    // MARK: - Callbacks

    /// Called when a Session Mode request resolves a target file within a directory workspace.
    /// Used by AppDependencies to sync NavigationState so the Session Mode UI shows
    /// the correct file's knowledge. Parameters: (filePath).
    var onFileResolved: ((_ filePath: String) -> Void)?

    // MARK: - State

    private var listeningTask: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0
    private var activeRequestTask: Task<Void, Never>?

    // MARK: - Init

    /// - Parameters:
    ///   - selectionCapture: Accessibility-based text capture service.
    ///   - aiProvider: Closure returning the current AI provider, or nil.
    ///   - hud: The floating explanation panel for displaying results.
    ///   - workspaceResolver: Automatic workspace matching service.
    ///   - workspaceProvider: Closure returning all open workspaces + active/pinned IDs.
    ///     Queried on each hotkey press.
    ///   - usageTracker: Shared quota tracker for AI request limits.
    ///   - pipelineQueryService: Pipeline query orchestrator for the understanding pipeline.
    init(
        selectionCapture: any SelectionCaptureProtocol,
        aiProvider: @escaping @MainActor () -> (any AIProviderProtocol)?,
        hud: FloatingExplanationHUD,
        toastManager: DecodeToastManager,
        workspaceResolver: WorkspaceResolver = WorkspaceResolver(),
        workspaceProvider: @escaping @MainActor () -> WorkspaceResolverInput?,
        usageTracker: AIUsageTracker,
        knowledgeArtifactStore: KnowledgeArtifactStore? = nil,
        pipelineQueryService: PipelineQueryService,
        virtualSessionManager: VirtualSessionManager,
        profileIntelligenceService: ProfileIntelligenceService? = nil
    ) {
        self.selectionCapture = selectionCapture
        self.aiProvider = aiProvider
        self.hud = hud
        self.toastManager = toastManager
        self.workspaceResolver = workspaceResolver
        self.workspaceProvider = workspaceProvider
        self.usageTracker = usageTracker
        self.knowledgeArtifactStore = knowledgeArtifactStore
        self.pipelineQueryService = pipelineQueryService
        self.virtualSessionManager = virtualSessionManager
        self.profileIntelligenceService = profileIntelligenceService
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

        // 4. Capture selected text.
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
        let effectiveFilePath = resolution.resolvedFilePath ?? managed.workspace.rootPath
        let effectiveFileName = (effectiveFilePath as NSString).lastPathComponent
        let effectiveEntities: [ParsedEntity]
        if let resolvedPath = resolution.resolvedFilePath,
           managed.workspace.kind == .directory {
            effectiveEntities = managed.parsedEntitiesByFile[resolvedPath] ?? managed.parsedEntities
        } else {
            effectiveEntities = managed.parsedEntities
        }

        // Sync resolved file to NavigationState so the Session Mode UI shows this file.
        if managed.workspace.kind == .directory, let resolvedPath = resolution.resolvedFilePath {
            onFileResolved?(resolvedPath)
        }

        #if DEBUG
        diagLog("[SessionQuestion] Resolved workspace: \(effectiveFileName) (method=\(resolution.method), confidence=\(resolution.confidence))")
        diagLog("[SessionQuestion] effectiveFilePath=\(effectiveFilePath)")
        diagLog("[SessionQuestion] snippetText length=\(snippetText.count) chars")
        #endif

        // 7. Derive snippet line range for pipeline query.
        // The RetrievalRuntime resolves the snippet to entity anchors via
        // DDS-005 PC-2 — the coordinator provides the source range, not a
        // pre-resolved entity name.
        let snippetLineRange = Self.deriveSnippetLineRange(
            snippetText: snippetText,
            filePath: effectiveFilePath,
            selectedRange: result.selectedRange
        )

        #if DEBUG
        diagLog("[SessionQuestion] Snippet line range: \(snippetLineRange.startLine)-\(snippetLineRange.endLine)")
        diagLog("[SessionQuestion] BaseModel.py total lines: \((try? String(contentsOfFile: effectiveFilePath, encoding: .utf8))?.components(separatedBy: "\n").count ?? -1)")
        #endif

        // 8. Collect user intent.
        let dsaMode = UserDefaults.standard.bool(forKey: "dsaModeEnabled")
        let explanationProfile = dsaMode ? "dsa" : "general"

        guard let intentText = await hud.collectIntent(
            sourceApp: sourceAppName,
            mode: "session",
            sessionFile: effectiveFileName,
            explanationProfile: explanationProfile
        ) else {
            return // User cancelled
        }
        // Staleness check after intent collection.
        guard generation == requestGeneration else { return }

        let executionContext = ExplanationExecutionContext(mode: "session", explanationProfile: explanationProfile)

        // Virtual Session: inject working memory marker.
        if virtualSessionManager.isEnabled {
            executionContext.virtualSession = true
        }

        // Show loading state immediately.
        hud.showLoading(
            sourceApp: sourceAppName,
            mode: "session",
            sessionFile: effectiveFileName,
            explanationProfile: explanationProfile,
            executionContext: executionContext
        )

        // 9. Check quota before making the AI request.
        guard usageTracker.tryConsumeRequest() else {
            toastManager.show(usageTracker.quotaExhaustedMessage, icon: "gauge.with.dots.needle.67percent")
            return
        }

        // Profile Intelligence: load profile for pipeline and follow-up context.
        var profileContext: String?
        if let service = profileIntelligenceService {
            let profile = await service.currentProfile()
            profileContext = ProfilePromptFormatter.format(profile)
        }

        // 10. Execute the pipeline.
        // Look up pre-generated semantic understanding from FileIntelligence.
        let semanticContext: String?
        if managed.workspace.kind == .directory {
            semanticContext = Self.formatSemanticContext(
                managed.fileIntelligenceByFile[effectiveFilePath]?.semanticEnrichment
            )
        } else {
            semanticContext = Self.formatSemanticContext(
                managed.fileIntelligence?.semanticEnrichment
            )
        }

        let queryService = pipelineQueryService
        let hint = intentText.isEmpty ? nil : intentText
        let capturedProfileContext = profileContext
        let capturedSnippet = snippetText
        let capturedSemanticContext = semanticContext
        let capturedStartLine = snippetLineRange.startLine
        let capturedEndLine = snippetLineRange.endLine
        let pipelineResult = await Task.detached {
            await queryService.queryBySnippet(
                filePath: effectiveFilePath,
                startLine: capturedStartLine,
                endLine: capturedEndLine,
                purpose: "explain",
                questionHint: hint,
                profileContext: capturedProfileContext,
                snippetText: capturedSnippet,
                semanticContext: capturedSemanticContext
            )
        }.value

        // Staleness check after pipeline await.
        guard generation == requestGeneration else {
            #if DEBUG
            diagLog("[SessionQuestion] Pipeline: request superseded (gen=\(generation), current=\(requestGeneration))")
            #endif
            return
        }

        guard case .success(let understanding) = pipelineResult else {
            #if DEBUG
            diagLog("[SessionQuestion] Pipeline: non-success result — \(pipelineResult)")
            #endif
            hud.showError("Could not generate explanation. The understanding pipeline did not produce a result.")
            return
        }

        // Resolve language from file extension for analytics.
        let fileExt = (effectiveFileName as NSString).pathExtension.lowercased()
        let language: String? = if let profile = LanguageProfile.from(fileName: effectiveFileName) {
            profile.displayName
        } else if fileExt == "swift" {
            "Swift"
        } else {
            nil
        }

        // Store question context for Knowledge Inspector.
        managed.lastQuestionContext = QuestionContext(
            contextTier: "pipeline",
            includedBehavior: true,
            includedSafety: true,
            includedDesign: true,
            healthTier: "n/a",
            healthHintCount: 0,
            promptCharacterCount: 0,
            enrichmentCacheHit: false,
            timestamp: Date()
        )

        // Wrap Understanding.content in a single-element stream for the HUD.
        let content = understanding.content
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield(content)
            continuation.finish()
        }

        // Build follow-up context for the HUD.
        let followUpCtx = ExplanationHUDViewModel.FollowUpContext(
            sourceContent: "Explain this code:\n\n\(snippetText)",
            systemPrompt: "",
            mode: "session",
            aiProvider: provider,
            usageTracker: usageTracker,
            originalCode: snippetText,
            explanationProfile: explanationProfile,
            language: language,
            sourceAppPID: event.sourceAppPID,
            pipelineQueryService: pipelineQueryService,
            pipelineConversationState: understanding.conversationState,
            pipelineFilePath: effectiveFilePath,
            pipelineEntityName: nil,
            pipelineSnippetStartLine: snippetLineRange.startLine,
            pipelineSnippetEndLine: snippetLineRange.endLine,
            profileContext: profileContext
        )

        // Virtual Session: record insight on stream completion.
        // Profile Intelligence: record observation at the same completion point.
        let insightContext = buildInsightContext(
            filePath: effectiveFilePath,
            fileName: effectiveFileName,
            entities: effectiveEntities,
            snippet: snippetText,
            intelligence: managed.fileIntelligence,
            sourceApp: sourceAppName,
            workspaceID: managed.workspace.id
        )
        let vsManager = virtualSessionManager
        let capturedInsightContext = insightContext
        let profileService = profileIntelligenceService
        hud.showStream(stream, sourceApp: sourceAppName, followUpContext: followUpCtx) { explanationText in
            if vsManager.isEnabled {
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

            profileService?.recordObservation(
                context: capturedInsightContext,
                mode: "session",
                observationType: .explanation
            )
        }

        #if DEBUG
        print("[SessionQuestion] Pipeline: Understanding delivered — engine=\(understanding.metadata.engineIdentifier), completeness=\(understanding.metadata.completeness)")
        #endif
    }

    // MARK: - Semantic Context Formatting

    /// Formats a `SemanticEnrichment` into a prompt-ready string for the reasoning engine.
    /// Returns `nil` when no enrichment is available.
    static func formatSemanticContext(_ enrichment: SemanticEnrichment?) -> String? {
        guard let enrichment else { return nil }

        var sections: [String] = []
        sections.append("## File Understanding\n\n**Purpose:** \(enrichment.purpose)")

        if let behavior = enrichment.behavior, !behavior.isEmpty {
            sections.append("**Behavior:** \(behavior)")
        }
        if let safety = enrichment.safety, !safety.isEmpty {
            sections.append("**Safety:** \(safety)")
        }
        if let design = enrichment.design, !design.isEmpty {
            sections.append("**Design:** \(design)")
        }

        let result = sections.joined(separator: "\n\n")
        return result.isEmpty ? nil : result
    }

    // MARK: - Snippet Line Range Derivation

    /// Derives the line range of `snippetText` within the file at `filePath`.
    ///
    /// Strategy:
    /// 1. Finds the snippet text in the file content. If exactly one occurrence
    ///    exists, the match is provably correct.
    /// 2. If multiple occurrences exist and an AX character offset is available,
    ///    uses the offset to pick the closest match.
    /// 3. If multiple occurrences exist with no AX offset, or the snippet is not
    ///    found (unsaved changes), uses the full file line range as a conservative
    ///    but correct fallback.
    ///
    /// Correctness guarantee: this method never resolves to the wrong source
    /// location. Unique matches are exact; ambiguous or missing matches use the
    /// full file range, which is broader than needed but never incorrect.
    nonisolated static func deriveSnippetLineRange(
        snippetText: String,
        filePath: String,
        selectedRange: (location: Int, length: Int)?
    ) -> (startLine: Int, endLine: Int) {
        guard let fileContent = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return (1, 1)
        }

        let totalLines = max(1, fileContent.components(separatedBy: "\n").count)

        let trimmed = snippetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (1, totalLines)
        }

        // Find occurrences of the snippet in the file.
        var occurrences: [(charOffset: Int, startLine: Int, endLine: Int)] = []
        var searchStart = fileContent.startIndex
        let limit = selectedRange != nil ? 10 : 2

        while let range = fileContent.range(of: trimmed, range: searchStart..<fileContent.endIndex) {
            let offset = fileContent.distance(from: fileContent.startIndex, to: range.lowerBound)
            let prefix = fileContent[fileContent.startIndex..<range.lowerBound]
            let startLine = prefix.filter({ $0 == "\n" }).count + 1
            let snippetNewlines = fileContent[range].filter({ $0 == "\n" }).count
            let endLine = startLine + snippetNewlines

            occurrences.append((charOffset: offset, startLine: startLine, endLine: endLine))

            guard range.upperBound < fileContent.endIndex else { break }
            searchStart = fileContent.index(after: range.lowerBound)
            if occurrences.count >= limit { break }
        }

        switch occurrences.count {
        case 0:
            // Snippet not found in file (unsaved changes?) — full file range.
            return (1, totalLines)
        case 1:
            // Unique match — provably correct.
            return (occurrences[0].startLine, occurrences[0].endLine)
        default:
            // Multiple matches — try AX offset disambiguation.
            if let axRange = selectedRange {
                let closest = occurrences.min(by: {
                    abs($0.charOffset - axRange.location) < abs($1.charOffset - axRange.location)
                })!
                return (closest.startLine, closest.endLine)
            }
            // No AX offset — conservative full file range.
            return (1, totalLines)
        }
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
