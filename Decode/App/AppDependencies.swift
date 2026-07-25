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

    // MARK: - Session Mode

    /// Manages all sessions: lifecycle, file watching, persistence, active session.
    /// Created during deferred startup after the database is available.
    private(set) var sessionManager: SessionManager?

    /// Shared view model for Session Mode UI, backed by ``sessionManager``.
    private(set) var sessionViewModel: SessionViewModel?

    private(set) var sessionQuestionCoordinator: SessionQuestionCoordinator?

    /// Semantic enrichment service for cache inspection by the Knowledge Inspector.
    private(set) var enrichmentService: SemanticEnrichmentService?

    /// Floating dock panel showing all sessions. Visible when sessions exist.
    private(set) var floatingDock: FloatingSessionDock?

    /// Observation task that watches session count and updates dock visibility.
    private var dockVisibilityTask: Task<Void, Never>?

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

        // 1. Build AI provider (Keychain access).
        rebuildAIProvider()

        // 1b. Create shared usage tracker.
        let tracker = AIUsageTracker()
        self.usageTracker = tracker

        // 2. Wire up coordinators.
        let selCoordinator = SelectionModeCoordinator(
            selectionCapture: selectionCapture,
            aiProvider: { [weak self] in self?.aiProvider },
            hud: hud,
            toastManager: toastManager,
            usageTracker: tracker
        )
        self.selectionCoordinator = selCoordinator

        let ssCoordinator = ScreenshotModeCoordinator(
            screenCapture: screenCapture,
            ocrService: ocrService,
            aiProvider: { [weak self] in self?.aiProvider },
            hud: hud,
            toastManager: toastManager,
            usageTracker: tracker
        )
        self.screenshotCoordinator = ssCoordinator

        // 2b. Session Mode: create manager, view model, and question coordinator.
        let manager = SessionManager(database: database)
        self.sessionManager = manager
        self.sessionViewModel = SessionViewModel(sessionManager: manager)

        // 2b-bridge. File monitoring bridge (IAG-004 §8.1, IC-10).
        // Route session file change events to the understanding pipeline.
        // Maps app-domain FileChangeKind → pipeline-domain UpdateEngine.FileChangeType.
        let understanding = self.understandingSystem
        manager.onFileChanged = { filePath, kind in
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

        // 2c. Session Dock: floating panel for session visibility.
        let dock = FloatingSessionDock(sessionManager: manager)
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

        // Watch session count to show/hide dock automatically.
        dockVisibilityTask = Task { [weak dock, weak manager] in
            // withObservationTracking loop: re-evaluate whenever sessions changes.
            while !Task.isCancelled {
                guard let dock, let manager else { break }
                let isEmpty = manager.sessions.isEmpty
                if isEmpty {
                    dock.hide()
                } else {
                    dock.updateVisibility()
                }
                // Suspend until the next observation change.
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = manager.sessions.count
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }

        let enrichment = SemanticEnrichmentService(
            aiProvider: { [weak self] in self?.aiProvider }
        )
        self.enrichmentService = enrichment
        let sqCoordinator = SessionQuestionCoordinator(
            selectionCapture: selectionCapture,
            aiProvider: { [weak self] in self?.aiProvider },
            hud: hud,
            toastManager: toastManager,
            sessionProvider: { [weak manager] in
                guard let manager else { return nil }
                guard !manager.sessions.isEmpty else { return nil }
                return SessionResolverInput(
                    sessions: manager.sessions,
                    activeSessionId: manager.activeSessionId,
                    pinnedSessionId: manager.pinnedSessionId
                )
            },
            usageTracker: tracker,
            semanticEnrichment: enrichment,
            pipelineQueryService: pipelineQueryService
        )
        self.sessionQuestionCoordinator = sqCoordinator

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

    /// Handle the ⌃⇧O hotkey: open file picker, create session, present sheet.
    private func handleOpenSession() {
        guard let vm = sessionViewModel else { return }

        // Bring Decode to the front so NSOpenPanel is visible.
        NSApp.activate(ignoringOtherApps: true)

        vm.openFile()

        // If a session is now active, signal the sheet to present.
        if vm.activeSession != nil {
            vm.shouldPresentSession = true
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



