import Foundation
import SwiftUI
import os.log
import ContextAssembly
import ConsumerRuntime
import UpdateEngine

private let startupLog = Logger(subsystem: "com.decode.app", category: "startup-diag")

/// The root dependency container for the application.
///
/// Owns all concrete infrastructure instances and exposes them as
/// protocol-typed properties. Constructed once at app launch in `DecodeApp`
/// and passed through the SwiftUI environment.
///
/// ## Activation-Safe Initialization
/// `init()` performs only lightweight object construction — no Keychain access,
/// no Accessibility prompts, no event monitor registration. All activation-
/// sensitive work is deferred to ``performDeferredStartup()``, which must be
/// called after the app has fully activated (e.g., on
/// `NSApplication.didBecomeActiveNotification`).
///
/// For tests, construct with mock/stub implementations of each protocol.
@Observable
@MainActor
final class AppDependencies {

    // MARK: - Authentication

    /// Authentication service. Created at init (lightweight), validated during deferred startup.
    let authService: AuthService

    // MARK: - Infrastructure Services

    let keychain: KeychainService
    let networkClient: AINetworkClient
    private(set) var database: DatabaseService?

    // MARK: - Selection Mode

    let hotkeyService: HotkeyService
    let selectionCapture: AccessibilityCapture
    let hud: FloatingExplanationHUD
    let toastManager: DecodeToastManager
    private(set) var selectionCoordinator: SelectionModeCoordinator?

    // MARK: - Screenshot Mode

    let screenCapture: ScreenCaptureServiceImpl
    let ocrService: VisionOCRService
    private(set) var screenshotCoordinator: ScreenshotModeCoordinator?

    // MARK: - Workspace Mode

    /// Manages all workspaces: lifecycle, file watching, persistence, active workspace.
    /// Created during deferred startup after the database is available.
    private(set) var workspaceManager: WorkspaceManager?

    /// Shared view model for Session Mode UI, backed by ``workspaceManager``.
    private(set) var sessionViewModel: SessionViewModel?

    private(set) var sessionQuestionCoordinator: SessionQuestionCoordinator?

    /// Semantic enrichment service for cache inspection by the Knowledge Inspector.
    private(set) var enrichmentService: SemanticEnrichmentService?

    /// Floating dock panel showing all workspaces. Visible when workspaces exist.
    private(set) var floatingDock: FloatingSessionDock?

    /// Observation task that watches workspace count and updates dock visibility.
    private var dockVisibilityTask: Task<Void, Never>?

    /// Floating launcher on the left screen edge for quick file/folder actions.
    private(set) var floatingLauncher: FloatingLauncher?

    // MARK: - Notes

    /// Service for saving and loading explanation notes.
    private(set) var noteService: NoteService?

    // MARK: - Feedback

    /// Manages feedback scheduling and submission.
    let feedbackManager = FeedbackManager()

    // MARK: - Virtual Sessions

    /// Manages optional cross-mode investigation memory.
    /// Created at init (lightweight). Restored during deferred startup.
    let virtualSessionManager: VirtualSessionManager

    // MARK: - Profile Intelligence

    /// Records user behavior observations and derives a learning profile.
    /// Created during deferred startup after the database is available.
    private(set) var profileIntelligenceService: ProfileIntelligenceService?

    // MARK: - Understanding Pipeline

    /// The understanding pipeline composition root (IAG-001 §6).
    /// Created at init (lightweight — no I/O). Started during deferred startup.
    /// Shutdown on app termination via willTerminateNotification.
    let understandingSystem: UnderstandingSystem

    /// Consumer invocation — the primary query entry point for the understanding pipeline (DDS-009:PC-1).
    var consumerInvocation: any ConsumerInvocation { understandingSystem.consumerInvocation }

    /// Pipeline query orchestrator — chains processChanges → retrieve → assemble → invoke.
    /// Created at init alongside UnderstandingSystem.
    let pipelineQueryService: PipelineQueryService

    /// Task running the understanding pipeline startup sequence.
    private var understandingStartupTask: Task<Void, Never>?

    // MARK: - Knowledge Generation Runtime

    /// Persistent cache for knowledge artifacts produced by the KGR.
    private(set) var knowledgeArtifactStore: KnowledgeArtifactStore?

    /// Determines which knowledge generation jobs need to run.
    private(set) var knowledgePlanner: KnowledgePlanner?

    /// Schedules and executes knowledge generation work items.
    private(set) var knowledgeRuntime: KnowledgeGenerationRuntime?

    // MARK: - AI Platform

    /// Centralized AI provider configuration loaded from environment variables.
    private(set) var aiConfiguration: AIConfiguration?

    /// Registry of all initialized AI providers indexed by identifier.
    private(set) var providerRegistry: AIProviderRegistry?

    /// Dedicated provider for background knowledge generation.
    /// Uses Groq for fast inference. Falls back to the primary provider
    /// (Claude via gateway) when GROQ_API_KEY is not configured.
    private(set) var knowledgeProvider: GroqProvider?

    // MARK: - Usage Tracking

    /// Shared quota tracker for AI request limits across all modes.
    private(set) var usageTracker: AIUsageTracker?

    // MARK: - Hotkey Fan-Out

    /// Task that consumes the single hotkey stream and fans out events
    /// to both coordinators' streams.
    private var hotkeyFanOutTask: Task<Void, Never>?

    // MARK: - AI Provider

    /// The active AI provider. Uses the Decode Gateway when authenticated.
    /// `nil` when not authenticated — use `isConfigured` to check readiness.
    private(set) var aiProvider: (any AIProviderProtocol)?

    /// Whether the AI provider is ready for requests.
    ///
    /// Returns `true` when the user is authenticated and the gateway provider
    /// is constructed. All three modes gate on this before calling the provider.
    var isConfigured: Bool { aiProvider != nil }

    // MARK: - Startup State

    /// Whether ``performDeferredStartup()`` has already run.
    /// Guards against duplicate calls (e.g., multiple `didBecomeActive` notifications).
    private var hasPerformedDeferredStartup = false

    // MARK: - Init (lightweight only)

    init(
        keychain: KeychainService = KeychainService(),
        networkClient: AINetworkClient = AINetworkClient()
    ) {
        self.keychain = keychain
        self.networkClient = networkClient
        self.authService = AuthService(keychain: keychain)

        #if DEBUG
        print("[DEBUG Startup] AppDependencies.init started")
        #endif

        // Create service objects — no I/O, no blocking calls.
        self.hotkeyService = HotkeyService()
        self.selectionCapture = AccessibilityCapture()
        self.hud = FloatingExplanationHUD()
        self.toastManager = DecodeToastManager()
        self.screenCapture = ScreenCaptureServiceImpl()
        self.ocrService = VisionOCRService()
        self.virtualSessionManager = VirtualSessionManager()

        // Understanding pipeline — lightweight construction only (no I/O).
        // Snapshot directory: ~/Library/Application Support/Decode/understanding/
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Decode", isDirectory: true)
        let snapshotDir = appSupport.appendingPathComponent("understanding", isDirectory: true)
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        self.understandingSystem = UnderstandingSystem(snapshotDirectory: snapshotDir)
        self.pipelineQueryService = PipelineQueryService(understandingSystem: understandingSystem)

        #if DEBUG
        print("[DEBUG Startup] AppDependencies.init complete")
        #endif
    }

    // MARK: - Deferred Startup

    /// Perform all activation-sensitive startup work.
    ///
    /// Call this **after** the app has fully activated — typically in response to
    /// `NSApplication.didBecomeActiveNotification`. This ensures the run loop,
    /// responder chain, menu bar, and window management are all fully initialized
    /// before we register event monitors, access Keychain, or prompt for permissions.
    ///
    /// Safe to call multiple times — only the first invocation performs work.
    func performDeferredStartup() {
        guard !hasPerformedDeferredStartup else { return }
        hasPerformedDeferredStartup = true

        startupLog.notice("[DIAG] performDeferredStartup — BEGIN")

        #if DEBUG
        print("[DEBUG Startup] performDeferredStartup — BEGIN")
        #endif

        // 0a. Validate authentication (non-blocking).
        // Rebuild the AI provider after auth completes so the gateway
        // token is available for the provider.
        Task { [weak self] in
            startupLog.notice("[DIAG] auth Task — START (inside Task)")
            await self?.authService.checkAuthOnLaunch()
            startupLog.notice("[DIAG] auth Task — checkAuthOnLaunch returned, rebuilding provider")
            self?.rebuildAIProvider()

            // Request Accessibility permission only after authentication succeeds.
            // This avoids showing a system permission dialog before the user
            // understands what Decode does (e.g., while the invite code screen is visible).
            if self?.authService.state == .authenticated {
                if let capture = self?.selectionCapture, !capture.hasAccessibilityPermission() {
                    capture.requestAccessibilityPermission()
                }
            }
            startupLog.notice("[DIAG] auth Task — END")
        }

        // 0b. Initialize database.
        do {
            database = try DatabaseService()
            #if DEBUG
            print("[DEBUG Startup] Database initialized successfully")
            #endif
        } catch {
            #if DEBUG
            print("[DEBUG Startup] Database initialization failed: \(error)")
            #endif
        }

        // 0b2. Initialize note service.
        if let db = database {
            let service = NoteService(database: db)
            self.noteService = service
            hud.viewModel.noteService = service
        }

        // 0b3. Initialize Profile Intelligence service.
        if let db = database {
            let repository = ProfileObservationRepository(database: db)
            self.profileIntelligenceService = ProfileIntelligenceService(repository: repository)
        }

        // 0b4. Wire feedback manager to HUD.
        hud.viewModel.feedbackManager = feedbackManager

        // 0c. Restore virtual session state.
        virtualSessionManager.restore()

        // 1. Build AI provider (Keychain access).
        rebuildAIProvider()

        // 1a. Wire AI provider into virtual session manager for compression.
        virtualSessionManager.aiProvider = { [weak self] in self?.aiProvider }

        // 1b. Create shared usage tracker.
        let tracker = AIUsageTracker()
        self.usageTracker = tracker

        // 1c. AI Platform — multi-provider architecture.
        //
        // AIConfiguration loads all provider config from environment once.
        // Providers receive their config via dependency injection.
        // AIProviderRegistry tracks all available providers.
        //
        // Primary provider (Claude via gateway): Explain, Follow-up, Improve.
        // Knowledge provider (Groq via direct API): FileUnderstandingJob, future
        //   ModuleUnderstandingJob, ArchitectureUnderstandingJob.
        //
        // If GROQ_API_KEY is not set, all capabilities fall back to Claude.
        let config = AIConfiguration.fromEnvironment()
        self.aiConfiguration = config
        config.logStatus()

        let registry = AIProviderRegistry()
        self.providerRegistry = registry

        // Initialize Groq provider from centralized configuration.
        let groqProvider = GroqProvider(config: config.groq, visionModel: config.groqVisionModel)
        self.knowledgeProvider = groqProvider
        registry.register(groqProvider, identifier: "groq", isAvailable: groqProvider.isAvailable)

        // 1d. Knowledge Generation Runtime.
        let artifactStore = KnowledgeArtifactStore()
        artifactStore.loadFromDisk()
        self.knowledgeArtifactStore = artifactStore

        // Primary executor: routes through the Decode Gateway → Claude.
        let primaryExecutor: CapabilityExecutor = { [weak self] userContent, systemPrompt, capability, mode in
            guard let provider = await MainActor.run(body: { self?.aiProvider }) else {
                throw KnowledgeGenerationError.noProvider
            }
            return try await provider.generateCompletion(
                userContent: userContent,
                systemPrompt: systemPrompt,
                mode: mode
            )
        }

        // Build the capability resolver: routed if Groq is available, uniform otherwise.
        let capabilityResolver: KnowledgeCapabilityResolver
        if groqProvider.isAvailable {
            // Knowledge executor: routes directly to Groq for background work.
            let knowledgeExecutor: CapabilityExecutor = { userContent, systemPrompt, capability, mode in
                return try await groqProvider.generateCompletion(
                    userContent: userContent,
                    systemPrompt: systemPrompt,
                    mode: mode
                )
            }

            capabilityResolver = KnowledgeCapabilityResolver.routed(
                routes: [
                    .fileSummarization: knowledgeExecutor,
                    .moduleSummarization: knowledgeExecutor,
                    .architectureSummarization: knowledgeExecutor,
                ],
                fallback: primaryExecutor
            )
        } else {
            capabilityResolver = KnowledgeCapabilityResolver.uniform(executor: primaryExecutor)
        }

        let planner = KnowledgePlanner(resolver: capabilityResolver)
        self.knowledgePlanner = planner

        let kgRuntime = KnowledgeGenerationRuntime(
            resolver: capabilityResolver,
            store: artifactStore
        )
        self.knowledgeRuntime = kgRuntime

        // Register FileUnderstandingJob with planner and runtime.
        let fileUnderstandingJob = FileUnderstandingJob()
        planner.register(fileUnderstandingJob)
        kgRuntime.registerJob(fileUnderstandingJob)

        // 2. Wire up coordinators.
        // Create VisualContextExtractor for Enhanced Explanation.
        // Routes vision requests through the Decode Gateway (Railway) → Groq Vision.
        // The gateway provider is always created — it uses the Keychain token closure
        // so it works even if rebuilt later. If not authenticated or GROQ_API_KEY is
        // not set server-side, the request fails and the extractor returns nil
        // (graceful degradation).
        let visionGatewayProvider = DecodeGatewayProvider(
            accessToken: { [weak self] in
                guard let keychain = self?.keychain else { return nil }
                return try? keychain.retrieve(forAccount: "decode-access-token")
            }
        )
        let vcExtractor = VisualContextExtractor(provider: visionGatewayProvider)

        let selCoordinator = SelectionModeCoordinator(
            selectionCapture: selectionCapture,
            aiProvider: { [weak self] in self?.aiProvider },
            hud: hud,
            toastManager: toastManager,
            usageTracker: tracker,
            virtualSessionManager: virtualSessionManager,
            visualContextExtractor: vcExtractor,
            profileIntelligenceService: profileIntelligenceService
        )
        self.selectionCoordinator = selCoordinator

        let ssCoordinator = ScreenshotModeCoordinator(
            screenCapture: screenCapture,
            ocrService: ocrService,
            aiProvider: { [weak self] in self?.aiProvider },
            hud: hud,
            toastManager: toastManager,
            usageTracker: tracker,
            virtualSessionManager: virtualSessionManager,
            visualContextExtractor: vcExtractor,
            profileIntelligenceService: profileIntelligenceService
        )
        self.screenshotCoordinator = ssCoordinator

        // 2b. Workspace Mode: create manager and view model.
        let wsManager = WorkspaceManager(database: database)
        self.workspaceManager = wsManager
        self.sessionViewModel = SessionViewModel(workspaceManager: wsManager)

        // 2b-bridge. File monitoring bridge (IAG-004 §8.1, IC-10).
        // Route workspace file change events to the understanding pipeline.
        // Maps app-domain FileChangeKind → pipeline-domain UpdateEngine.FileChangeType.
        let understanding = self.understandingSystem
        wsManager.onFileChanged = { filePath, kind in
            let changeType: UpdateEngine.FileChangeType
            switch kind {
            case .modified:
                changeType = .modified
            case .deleted:
                changeType = .deleted
            case .moved:
                changeType = .modified
            case .inaccessible:
                return
            }
            let event = UpdateEngine.FileChangeEvent(filePath: filePath, changeType: changeType)
            Task.detached {
                _ = await understanding.processChanges([event])
            }
        }

        // Wire processChanges closure for directory workspace indexing.
        wsManager.processChanges = { events in
            await understanding.processChanges(events)
        }

        // Restore workspaces from database.
        Task { [weak wsManager] in
            await wsManager?.restoreWorkspaces()
        }

        // 2c. Session Dock: floating panel for workspace visibility.
        let dock = FloatingSessionDock(workspaceManager: wsManager)
        dock.onOpenSessionMode = { [weak self] id in
            guard let self, let vm = self.sessionViewModel else { return }
            NSApp.activate(ignoringOtherApps: true)
            if let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) }) {
                mainWindow.makeKeyAndOrderFront(nil)
            }
            vm.shouldPresentSession = false
            vm.shouldPresentSession = true
        }
        self.floatingDock = dock

        // Watch workspace count to show/hide dock automatically.
        dockVisibilityTask = Task { [weak dock, weak wsManager] in
            // withObservationTracking loop: re-evaluate whenever workspaces changes.
            while !Task.isCancelled {
                guard let dock, let wsManager else { break }
                let isEmpty = wsManager.workspaces.isEmpty
                if isEmpty {
                    dock.hide()
                } else {
                    dock.updateVisibility()
                }
                // Suspend until the next observation change.
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = wsManager.workspaces.count
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }

        // 2d. Floating Launcher: always-visible left-edge launcher.
        let launcher = FloatingLauncher()
        launcher.onAddFile = { [weak self] in
            self?.handleOpenSession()
        }
        launcher.onAddFolder = { [weak self] in
            self?.handleOpenWorkspace()
        }
        launcher.onLauncherTapped = {
            NSApp.activate(ignoringOtherApps: true)
            if let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) }) {
                mainWindow.makeKeyAndOrderFront(nil)
            }
        }
        self.floatingLauncher = launcher
        launcher.show()

        let enrichment = SemanticEnrichmentService(
            aiProvider: { [weak self] in self?.aiProvider }
        )
        self.enrichmentService = enrichment
        let sqCoordinator = SessionQuestionCoordinator(
            selectionCapture: selectionCapture,
            aiProvider: { [weak self] in self?.aiProvider },
            hud: hud,
            toastManager: toastManager,
            workspaceProvider: { [weak wsManager] in
                guard let wsManager else { return nil }
                guard !wsManager.workspaces.isEmpty else { return nil }
                return WorkspaceResolverInput(
                    workspaces: wsManager.workspaces,
                    activeWorkspaceId: wsManager.activeWorkspaceId,
                    pinnedWorkspaceId: wsManager.pinnedWorkspaceId
                )
            },
            usageTracker: tracker,
            knowledgeArtifactStore: artifactStore,
            pipelineQueryService: pipelineQueryService,
            virtualSessionManager: virtualSessionManager,
            profileIntelligenceService: profileIntelligenceService
        )
        self.sessionQuestionCoordinator = sqCoordinator

        // 2e. Wire KGR trigger: when WorkspaceManager signals that files
        //     are ready (after indexing or file creation/reparse), plan and
        //     enqueue knowledge generation work items.
        wsManager.onKnowledgeGenerationNeeded = { [weak planner, weak kgRuntime, weak artifactStore] workspaceId, filePaths, fileHashes, fileIntelligences in
            guard let planner, let kgRuntime, let artifactStore else { return }

            let policy = KnowledgePolicy.live(aiAvailable: true)

            let workItems = planner.planForFiles(
                filePaths,
                fileHashes: fileHashes,
                fileIntelligences: fileIntelligences,
                workspaceId: workspaceId,
                store: artifactStore,
                policy: policy
            )

            if !workItems.isEmpty {
                kgRuntime.resetProgress()
                kgRuntime.enqueue(workItems)
            }
        }

        // 2f. Wire KGR artifact hydration: when a knowledge artifact is generated,
        //     decode it and hydrate the workspace's FileIntelligence so UI updates immediately.
        kgRuntime.onArtifactGenerated = { [weak wsManager] workspaceId, filePath, jobIdentifier, data in
            guard jobIdentifier == "file-understanding" else { return }
            guard let enrichment = FileUnderstandingJob.decodeEnrichment(from: data) else { return }
            wsManager?.hydrateSemanticEnrichment(workspaceId: workspaceId, filePath: filePath, enrichment: enrichment)
        }

        // 2g. Wire existing artifact loading: when WorkspaceManager builds FileIntelligence
        //     for a file, check if KGR already has a cached artifact for that file hash.
        wsManager.loadExistingEnrichment = { [weak artifactStore] filePath, fileHash in
            guard let artifactStore else { return nil }
            guard let entry = artifactStore.lookup(
                jobIdentifier: "file-understanding",
                filePath: filePath,
                contentHash: fileHash
            ) else { return nil }
            return FileUnderstandingJob.decodeEnrichment(from: entry.data)
        }

        // 2h. Wire resolved file sync: when SessionQuestionCoordinator resolves a file
        //     within a directory workspace, update NavigationState so the UI reflects it.
        sqCoordinator.onFileResolved = { [weak self] filePath in
            self?.sessionViewModel?.navigationState.selectFile(path: filePath)
        }

        // 2d. Start understanding pipeline (IAG-004 §8.1: called from performDeferredStartup).
        // Runs async — does not block deferred startup. No @MainActor on pipeline (IAG-003 §6.3).
        // After startup, register reasoning engines (DDS-009 PC-2).
        let aiProviderClosure: @Sendable () async -> (any AIProviderProtocol)? = { [weak self] in
            await MainActor.run { self?.aiProvider }
        }
        let explainEngine = ExplainReasoningEngine(aiProvider: aiProviderClosure)
        let improveEngine = ImproveReasoningEngine(aiProvider: aiProviderClosure)
        let followUpEngine = FollowUpReasoningEngine(aiProvider: aiProviderClosure)

        understandingStartupTask = Task.detached { [understandingSystem] in
            await understandingSystem.start()

            // Register reasoning engines (DDS-009 PC-2).
            _ = await understandingSystem.engineManagement.register(EngineRegistration(
                purpose: ContextPurpose("explain"),
                engineIdentifier: ExplainReasoningEngine.identifier,
                engineVersion: ExplainReasoningEngine.version,
                engine: explainEngine,
                isFallback: false
            ))
            _ = await understandingSystem.engineManagement.register(EngineRegistration(
                purpose: ContextPurpose("improve"),
                engineIdentifier: ImproveReasoningEngine.identifier,
                engineVersion: ImproveReasoningEngine.version,
                engine: improveEngine,
                isFallback: false
            ))
            _ = await understandingSystem.engineManagement.register(EngineRegistration(
                purpose: ContextPurpose("followup"),
                engineIdentifier: FollowUpReasoningEngine.identifier,
                engineVersion: FollowUpReasoningEngine.version,
                engine: followUpEngine,
                isFallback: false
            ))

            // Register production frontend producers (IAG-004 §18).
            // SwiftSyntax frontend: Swift source files → T0 atomic units.
            // Tree-sitter frontend: all other supported languages → T0 atomic units.
            do {
                _ = try await understandingSystem.registerFrontendHandler(
                    SwiftSyntaxFrontend.contract,
                    handler: SwiftSyntaxFrontend.handler
                )
                _ = try await understandingSystem.registerFrontendHandler(
                    TreeSitterFrontend.contract,
                    handler: TreeSitterFrontend.handler
                )
            } catch {
                #if DEBUG
                print("[DEBUG Startup] Frontend registration failed: \(error)")
                #endif
            }

            // Register composition passes (PI-001: Module boundary detection).
            do {
                _ = try await understandingSystem.registerPassHandler(
                    ModuleBoundaryPass.contract,
                    handler: ModuleBoundaryPass.handler
                )
            } catch {
                #if DEBUG
                print("[DEBUG Startup] Pass registration failed: \(error)")
                #endif
            }

            // Register resolution passes (M1: Cross-file entity resolution).
            do {
                _ = try await understandingSystem.registerPassHandler(
                    CrossFileResolutionPass.contract,
                    handler: CrossFileResolutionPass.handler
                )
            } catch {
                #if DEBUG
                print("[DEBUG Startup] Cross-file resolution pass registration failed: \(error)")
                #endif
            }

            // Register emergence passes (M4: Module emergent properties).
            do {
                _ = try await understandingSystem.registerPassHandler(
                    ModuleEmergentPropertiesPass.contract,
                    handler: ModuleEmergentPropertiesPass.handler
                )
            } catch {
                #if DEBUG
                print("[DEBUG Startup] Module emergent properties pass registration failed: \(error)")
                #endif
            }

            // Register system composition pass (M8: System entity creation).
            do {
                _ = try await understandingSystem.registerPassHandler(
                    SystemCompositionPass.contract,
                    handler: SystemCompositionPass.handler
                )
            } catch {
                #if DEBUG
                print("[DEBUG Startup] System composition pass registration failed: \(error)")
                #endif
            }

            // Register system emergent properties pass (M9: System-level emergence).
            do {
                _ = try await understandingSystem.registerPassHandler(
                    SystemEmergentPropertiesPass.contract,
                    handler: SystemEmergentPropertiesPass.handler
                )
            } catch {
                #if DEBUG
                print("[DEBUG Startup] System emergent properties pass registration failed: \(error)")
                #endif
            }

            // Register context assembly strategies (DDS-006 CS-R1).
            for strategy in ContextStrategies.all {
                let result = understandingSystem.strategyManagement.register(strategy)
                #if DEBUG
                if case .failure(let error) = result {
                    print("[DEBUG Startup] Strategy registration failed for \(strategy.purpose): \(error)")
                }
                #endif
            }

            #if DEBUG
            print("[DEBUG Startup] UnderstandingSystem started, engines + frontends + strategies registered")
            #endif
        }

        // 3. Start hotkey listening with fan-out to coordinators + session open handler.
        //    AsyncStream is single-consumer, so we consume it once and
        //    yield each event into separate streams.
        let sourceStream = hotkeyService.startListening()

        let (selStream, selContinuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        let (ssStream, ssContinuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        let (sqStream, sqContinuation) = AsyncStream.makeStream(of: HotkeyEvent.self)

        hotkeyFanOutTask = Task { [weak self] in
            for await event in sourceStream {
                if Task.isCancelled { break }

                if event.action == .openSession {
                    // Handle session open directly — no coordinator needed.
                    self?.handleOpenSession()
                }

                if event.action == .openWorkspace {
                    self?.handleOpenWorkspace()
                }

                selContinuation.yield(event)
                ssContinuation.yield(event)
                sqContinuation.yield(event)
            }
            selContinuation.finish()
            ssContinuation.finish()
            sqContinuation.finish()
        }

        selCoordinator.startListening(hotkeyStream: selStream)
        ssCoordinator.startListening(hotkeyStream: ssStream)
        sqCoordinator.startListening(hotkeyStream: sqStream)

        #if DEBUG
        print("[DEBUG Startup] performDeferredStartup — COMPLETE — AI=\(isConfigured), AX=\(selectionCapture.hasAccessibilityPermission()), selectionCoordinator=\(selectionCoordinator != nil), screenshotCoordinator=\(screenshotCoordinator != nil), sessionQuestionCoordinator=\(sessionQuestionCoordinator != nil)")
        #endif
    }

    // MARK: - Shutdown

    /// Shuts down the understanding pipeline (IAG-003 §4.2).
    /// Called from willTerminateNotification handler in DecodeApp.
    func shutdownUnderstandingPipeline() async {
        understandingStartupTask?.cancel()
        understandingStartupTask = nil
        await understandingSystem.shutdown()
    }

    // MARK: - Session Open (Hotkey)

    /// Handle the ⌃⇧O hotkey: open file picker, create workspace, present sheet.
    private func handleOpenSession() {
        guard workspaceManager != nil else { return }

        // Bring Decode to the front so NSOpenPanel is visible.
        NSApp.activate(ignoringOtherApps: true)

        // Open file picker — same panel config as SessionViewModel.openFile().
        let panel = NSOpenPanel()
        panel.title = "Select code files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }

            // Create workspaces for the selected files.
            if let vm = self.sessionViewModel {
                for url in urls {
                    await vm.loadFile(url: url)
                }
            }

            // Present session sheet if a workspace is now active.
            if let vm = self.sessionViewModel, vm.activeWorkspace != nil {
                vm.shouldPresentSession = true
            }
        }
    }

    // MARK: - Workspace Open (Hotkey)

    /// Handle the ⌃⇧P hotkey: open folder picker, create directory workspace, present sheet.
    private func handleOpenWorkspace() {
        guard sessionViewModel != nil else { return }

        // Bring Decode to the front so NSOpenPanel is visible.
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Select a project folder"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { [weak self] in
            guard let self else { return }

            if let vm = self.sessionViewModel {
                await vm.loadDirectory(url: url)
            }

            // Present session sheet if a workspace is now active.
            if let vm = self.sessionViewModel, vm.activeWorkspace != nil {
                vm.shouldPresentSession = true
            }
        }
    }

    // MARK: - Provider Management

    /// Rebuild the AI provider using the Decode Gateway.
    ///
    /// Creates a ``DecodeGatewayProvider`` that authenticates via the user's
    /// access token. Sets `aiProvider` to `nil` if no token is stored.
    ///
    /// Call this after authentication state changes.
    func rebuildAIProvider() {
        let keychain = self.keychain

        // Gateway provider uses the Decode access token, not per-provider API keys.
        let provider = DecodeGatewayProvider(
            accessToken: {
                try? keychain.retrieve(forAccount: "decode-access-token")
            }
        )

        // Only set the provider if we have a token.
        guard let token = try? keychain.retrieve(forAccount: "decode-access-token"),
              !token.isEmpty
        else {
            aiProvider = nil
            return
        }

        aiProvider = provider

        #if DEBUG
        print("[DEBUG Provider] Gateway provider configured")
        #endif
    }
}
