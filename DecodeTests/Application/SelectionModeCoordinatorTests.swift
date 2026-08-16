import Foundation
import Testing
@testable import Decode

// MARK: - Test Helpers

/// Creates a ``HotkeyEvent`` for `.explainSelection` with a test PID and app name.
private func makeExplainEvent(
    pid: pid_t = 12345,
    appName: String? = "Xcode"
) -> HotkeyEvent {
    HotkeyEvent(action: .explainSelection, sourceAppPID: pid, sourceAppName: appName)
}

/// Creates a ``HotkeyEvent`` for `.captureScreenshot`.
private func makeScreenshotEvent() -> HotkeyEvent {
    HotkeyEvent(action: .captureScreenshot, sourceAppPID: 12345, sourceAppName: "Xcode")
}

// MARK: - Mocks

/// Mock selection capture for testing coordinator flow.
private final class MockSelectionCapture: SelectionCaptureProtocol, @unchecked Sendable {
    var permissionGranted = true
    var capturedResult: SelectionCaptureResult? = SelectionCaptureResult(
        text: "func hello() {}",
        sourceApplicationName: "Xcode"
    )
    var captureError: Error?
    var permissionRequested = false
    var lastCapturedPID: pid_t?

    func captureSelection(fromPID pid: pid_t) async throws -> SelectionCaptureResult? {
        lastCapturedPID = pid
        if let error = captureError { throw error }
        return capturedResult
    }

    func hasAccessibilityPermission() -> Bool {
        permissionGranted
    }

    func requestAccessibilityPermission() {
        permissionRequested = true
    }
}

/// Mock AI provider for testing coordinator flow.
private final class MockAIProvider: AIProviderProtocol, @unchecked Sendable {
    var streamTokens: [String] = ["Hello", " World"]
    var streamError: Error?
    var lastMessages: [AIMessage]?
    var lastSystemPrompt: String?

    func generateCompletion(userContent: String, systemPrompt: String, mode: String?) async throws -> String {
        "mock completion"
    }

    func streamChat(
        messages: [AIMessage],
        systemPrompt: String,
        mode: String?,
        contextTier: String?,
        explanationProfile: String?,
        language: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        lastMessages = messages
        lastSystemPrompt = systemPrompt

        if let error = streamError { throw error }

        let tokens = streamTokens
        return AsyncThrowingStream { continuation in
            for token in tokens {
                continuation.yield(token)
            }
            continuation.finish()
        }
    }

    func validateConnection() async throws {}
}

// MARK: - Tests

@Suite(.serialized)
struct SelectionModeCoordinatorTests {

    // MARK: - Happy Path

    @Test @MainActor
    func explainSelectionStreamsToHUD() async throws {
        let capture = MockSelectionCapture()
        let provider = MockAIProvider()
        let hud = FloatingExplanationHUD()

        let coordinator = SelectionModeCoordinator(
            selectionCapture: capture,
            aiProvider: { provider },
            hud: hud,
            toastManager: DecodeToastManager(),
            usageTracker: AIUsageTracker(),
            virtualSessionManager: VirtualSessionManager()
        )

        let (stream, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        coordinator.startListening(hotkeyStream: stream)

        continuation.yield(makeExplainEvent())
        continuation.finish()

        // Let the coordinator reach collectIntent() and register the continuation.
        try await Task.sleep(for: .milliseconds(50))
        // Resolve intent with default (empty string = Enter key).
        hud.viewModel.submitIntent()
        // Let the AI call and stream complete.
        try await Task.sleep(for: .milliseconds(100))

        // Provider should have received the captured text.
        #expect(provider.lastMessages?.first?.content == "func hello() {}")
        #expect(provider.lastMessages?.first?.role == .user)
        #expect(provider.lastSystemPrompt?.contains("code explanation") == true)

        // HUD should have received the stream and show accumulated text.
        #expect(hud.viewModel.explanationText == "Hello World")
        #expect(hud.viewModel.displayState == .complete)
        #expect(hud.viewModel.sourceAppName == "Xcode")

        coordinator.stopListening()
    }

    @Test @MainActor
    func captureUsesProvidedPID() async throws {
        let capture = MockSelectionCapture()
        let provider = MockAIProvider()
        let hud = FloatingExplanationHUD()

        let coordinator = SelectionModeCoordinator(
            selectionCapture: capture,
            aiProvider: { provider },
            hud: hud,
            toastManager: DecodeToastManager(),
            usageTracker: AIUsageTracker(),
            virtualSessionManager: VirtualSessionManager()
        )

        let (stream, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        coordinator.startListening(hotkeyStream: stream)

        continuation.yield(makeExplainEvent(pid: 99999, appName: "Safari"))
        continuation.finish()

        try await Task.sleep(for: .milliseconds(100))

        // Capture should have received the PID from the hotkey event.
        #expect(capture.lastCapturedPID == 99999)
        // Source app name should come from the hotkey event.
        #expect(hud.viewModel.sourceAppName == "Safari")

        coordinator.stopListening()
    }

    // MARK: - Error: AI Not Configured (now toast, HUD stays idle)

    @Test @MainActor
    func showsToastWhenAINotConfigured() async throws {
        let capture = MockSelectionCapture()
        let hud = FloatingExplanationHUD()

        let coordinator = SelectionModeCoordinator(
            selectionCapture: capture,
            aiProvider: { nil },
            hud: hud,
            toastManager: DecodeToastManager(),
            usageTracker: AIUsageTracker(),
            virtualSessionManager: VirtualSessionManager()
        )

        let (stream, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        coordinator.startListening(hotkeyStream: stream)

        continuation.yield(makeExplainEvent())
        continuation.finish()

        try await Task.sleep(for: .milliseconds(100))

        // HUD should NOT be used for operational errors — stays idle.
        #expect(hud.viewModel.displayState == .idle)

        coordinator.stopListening()
    }

    // MARK: - Error: No Accessibility Permission (now toast)

    @Test @MainActor
    func showsToastAndRequestsPermissionWhenMissing() async throws {
        let capture = MockSelectionCapture()
        capture.permissionGranted = false
        let provider = MockAIProvider()
        let hud = FloatingExplanationHUD()

        let coordinator = SelectionModeCoordinator(
            selectionCapture: capture,
            aiProvider: { provider },
            hud: hud,
            toastManager: DecodeToastManager(),
            usageTracker: AIUsageTracker(),
            virtualSessionManager: VirtualSessionManager()
        )

        let (stream, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        coordinator.startListening(hotkeyStream: stream)

        continuation.yield(makeExplainEvent())
        continuation.finish()

        try await Task.sleep(for: .milliseconds(100))

        // HUD stays idle; toast handles the message.
        #expect(hud.viewModel.displayState == .idle)
        #expect(capture.permissionRequested == true)
        #expect(provider.lastMessages == nil)

        coordinator.stopListening()
    }

    // MARK: - Error: No Text Selected (now toast)

    @Test @MainActor
    func showsToastWhenNoTextSelected() async throws {
        let capture = MockSelectionCapture()
        capture.capturedResult = nil
        let provider = MockAIProvider()
        let hud = FloatingExplanationHUD()

        let coordinator = SelectionModeCoordinator(
            selectionCapture: capture,
            aiProvider: { provider },
            hud: hud,
            toastManager: DecodeToastManager(),
            usageTracker: AIUsageTracker(),
            virtualSessionManager: VirtualSessionManager()
        )

        let (stream, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        coordinator.startListening(hotkeyStream: stream)

        continuation.yield(makeExplainEvent())
        continuation.finish()

        try await Task.sleep(for: .milliseconds(100))

        // HUD stays idle; toast handles the message.
        #expect(hud.viewModel.displayState == .idle)

        coordinator.stopListening()
    }

    // MARK: - Error: No Source App PID (now toast)

    @Test @MainActor
    func showsToastWhenNoSourceAppPID() async throws {
        let capture = MockSelectionCapture()
        let provider = MockAIProvider()
        let hud = FloatingExplanationHUD()

        let coordinator = SelectionModeCoordinator(
            selectionCapture: capture,
            aiProvider: { provider },
            hud: hud,
            toastManager: DecodeToastManager(),
            usageTracker: AIUsageTracker(),
            virtualSessionManager: VirtualSessionManager()
        )

        let (stream, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        coordinator.startListening(hotkeyStream: stream)

        // Event with nil PID
        let event = HotkeyEvent(action: .explainSelection, sourceAppPID: nil, sourceAppName: nil)
        continuation.yield(event)
        continuation.finish()

        try await Task.sleep(for: .milliseconds(100))

        // HUD stays idle; toast handles the message.
        #expect(hud.viewModel.displayState == .idle)

        coordinator.stopListening()
    }

    // MARK: - Error: Capture Failure (now toast)

    @Test @MainActor
    func showsToastWhenCaptureFails() async throws {
        let capture = MockSelectionCapture()
        capture.captureError = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "AX element unavailable",
        ])
        let provider = MockAIProvider()
        let hud = FloatingExplanationHUD()

        let coordinator = SelectionModeCoordinator(
            selectionCapture: capture,
            aiProvider: { provider },
            hud: hud,
            toastManager: DecodeToastManager(),
            usageTracker: AIUsageTracker(),
            virtualSessionManager: VirtualSessionManager()
        )

        let (stream, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        coordinator.startListening(hotkeyStream: stream)

        continuation.yield(makeExplainEvent())
        continuation.finish()

        try await Task.sleep(for: .milliseconds(100))

        // HUD stays idle; toast handles the message.
        #expect(hud.viewModel.displayState == .idle)

        coordinator.stopListening()
    }

    // MARK: - Error: AI Stream Failure (stays in HUD — after loading started)

    @Test @MainActor
    func showsErrorInHUDWhenStreamChatThrows() async throws {
        let capture = MockSelectionCapture()
        let provider = MockAIProvider()
        provider.streamError = AIProviderError.apiKeyMissing
        let hud = FloatingExplanationHUD()

        let coordinator = SelectionModeCoordinator(
            selectionCapture: capture,
            aiProvider: { provider },
            hud: hud,
            toastManager: DecodeToastManager(),
            usageTracker: AIUsageTracker(),
            virtualSessionManager: VirtualSessionManager()
        )

        let (stream, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        coordinator.startListening(hotkeyStream: stream)

        continuation.yield(makeExplainEvent())
        continuation.finish()

        // Let the coordinator reach collectIntent() and register the continuation.
        try await Task.sleep(for: .milliseconds(50))
        // Resolve intent with default (empty string = Enter key).
        hud.viewModel.submitIntent()
        // Let the AI call complete.
        try await Task.sleep(for: .milliseconds(100))

        // AI failure after loading started → stays in HUD.
        #expect(hud.viewModel.displayState == .error)
        #expect(hud.viewModel.errorMessage.contains("AI request failed"))

        coordinator.stopListening()
    }

    // MARK: - Screenshot Action (Phase 3 no-op)

    @Test @MainActor
    func screenshotActionIsNoOp() async throws {
        let capture = MockSelectionCapture()
        let provider = MockAIProvider()
        let hud = FloatingExplanationHUD()

        let coordinator = SelectionModeCoordinator(
            selectionCapture: capture,
            aiProvider: { provider },
            hud: hud,
            toastManager: DecodeToastManager(),
            usageTracker: AIUsageTracker(),
            virtualSessionManager: VirtualSessionManager()
        )

        let (stream, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        coordinator.startListening(hotkeyStream: stream)

        continuation.yield(makeScreenshotEvent())
        continuation.finish()

        try await Task.sleep(for: .milliseconds(100))

        #expect(hud.viewModel.displayState == .idle)
        #expect(provider.lastMessages == nil)

        coordinator.stopListening()
    }

    // MARK: - Lifecycle

    @Test @MainActor
    func stopListeningIsIdempotent() {
        let coordinator = SelectionModeCoordinator(
            selectionCapture: MockSelectionCapture(),
            aiProvider: { nil },
            hud: FloatingExplanationHUD(),
            toastManager: DecodeToastManager(),
            usageTracker: AIUsageTracker(),
            virtualSessionManager: VirtualSessionManager()
        )

        coordinator.stopListening()
        coordinator.stopListening()
    }

    // MARK: - System Prompt

    @Test @MainActor
    func systemPromptIncludesSourceApp() async throws {
        let capture = MockSelectionCapture()
        capture.capturedResult = SelectionCaptureResult(
            text: "let x = 1",
            sourceApplicationName: "Safari"
        )
        let provider = MockAIProvider()
        let hud = FloatingExplanationHUD()

        let coordinator = SelectionModeCoordinator(
            selectionCapture: capture,
            aiProvider: { provider },
            hud: hud,
            toastManager: DecodeToastManager(),
            usageTracker: AIUsageTracker(),
            virtualSessionManager: VirtualSessionManager()
        )

        let (stream, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        coordinator.startListening(hotkeyStream: stream)

        continuation.yield(makeExplainEvent(appName: "Safari"))
        continuation.finish()

        // Let the coordinator reach collectIntent() and register the continuation.
        try await Task.sleep(for: .milliseconds(50))
        // Resolve intent with default (empty string = Enter key).
        hud.viewModel.submitIntent()
        // Let the AI call complete.
        try await Task.sleep(for: .milliseconds(100))

        #expect(provider.lastSystemPrompt?.contains("Safari") == true)

        coordinator.stopListening()
    }

    @Test @MainActor
    func systemPromptOmitsSourceAppWhenNil() async throws {
        let capture = MockSelectionCapture()
        capture.capturedResult = SelectionCaptureResult(
            text: "let x = 1",
            sourceApplicationName: nil
        )
        let provider = MockAIProvider()
        let hud = FloatingExplanationHUD()

        let coordinator = SelectionModeCoordinator(
            selectionCapture: capture,
            aiProvider: { provider },
            hud: hud,
            toastManager: DecodeToastManager(),
            usageTracker: AIUsageTracker(),
            virtualSessionManager: VirtualSessionManager()
        )

        let (stream, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        coordinator.startListening(hotkeyStream: stream)

        continuation.yield(makeExplainEvent(appName: nil))
        continuation.finish()

        // Let the coordinator reach collectIntent() and register the continuation.
        try await Task.sleep(for: .milliseconds(50))
        // Resolve intent with default (empty string = Enter key).
        hud.viewModel.submitIntent()
        // Let the AI call complete.
        try await Task.sleep(for: .milliseconds(100))

        #expect(provider.lastSystemPrompt?.contains("selected in") == false)

        coordinator.stopListening()
    }
}
