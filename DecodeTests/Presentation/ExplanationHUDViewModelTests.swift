import Foundation
import Testing
@testable import Decode

/// Tests for ``ExplanationHUDViewModel`` state transitions.
@Suite(.serialized)
struct ExplanationHUDViewModelTests {

    // MARK: - Initial State

    @Test @MainActor
    func initialStateIsIdle() {
        let vm = ExplanationHUDViewModel()
        #expect(vm.displayState == .idle)
        #expect(vm.explanationText == "")
        #expect(vm.errorMessage == "")
        #expect(vm.sourceAppName == nil)
        #expect(vm.isVisible == false)
        #expect(vm.isStreaming == false)
    }

    // MARK: - Streaming

    @Test @MainActor
    func showStreamTransitionsToLoading() async throws {
        let vm = ExplanationHUDViewModel()

        let stream = AsyncThrowingStream<String, Error> { continuation in
            // Don't yield anything yet — hold the stream open.
            continuation.onTermination = { _ in }
        }

        vm.showStream(stream, sourceApp: "Xcode")

        #expect(vm.displayState == .loading)
        #expect(vm.isVisible == true)
        #expect(vm.isStreaming == true)
        #expect(vm.sourceAppName == "Xcode")
        #expect(vm.explanationText == "")

        vm.dismiss()
    }

    @Test @MainActor
    func showStreamAccumulatesTokens() async throws {
        let vm = ExplanationHUDViewModel()

        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("Hello")
            continuation.yield(" World")
            continuation.finish()
        }

        vm.showStream(stream, sourceApp: nil)

        // Give the Task time to consume the stream.
        try await Task.sleep(for: .milliseconds(50))

        #expect(vm.explanationText == "Hello World")
        #expect(vm.displayState == .complete)
        #expect(vm.isStreaming == false)
        #expect(vm.isVisible == true)
    }

    @Test @MainActor
    func showStreamTransitionsToStreamingOnFirstToken() async throws {
        let vm = ExplanationHUDViewModel()

        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("First")
            continuation.finish()
        }

        vm.showStream(stream, sourceApp: nil)
        try await Task.sleep(for: .milliseconds(50))

        // After tokens arrive and stream finishes, should be complete.
        #expect(vm.displayState == .complete)
        #expect(vm.explanationText == "First")
    }

    @Test @MainActor
    func showStreamHandlesError() async throws {
        let vm = ExplanationHUDViewModel()

        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "Test failure" }
        }

        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("Partial")
            continuation.finish(throwing: TestError())
        }

        vm.showStream(stream, sourceApp: "Safari")
        try await Task.sleep(for: .milliseconds(50))

        // Production intentionally transitions to .complete when partial content
        // was received before the error — preserves visible partial explanation.
        // Only transitions to .error when no content was received at all.
        #expect(vm.displayState == .complete)
        #expect(vm.explanationText == "Partial")
        #expect(vm.errorMessage == "Test failure")
        #expect(vm.isVisible == true)
        #expect(vm.isStreaming == false)
    }

    @Test @MainActor
    func showStreamCancelsPreviousStream() async throws {
        let vm = ExplanationHUDViewModel()

        // First stream: never finishes.
        let firstStream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("Old content")
            // Hold open — no finish().
            continuation.onTermination = { _ in }
        }

        vm.showStream(firstStream, sourceApp: "Terminal")
        try await Task.sleep(for: .milliseconds(50))

        #expect(vm.explanationText == "Old content")

        // Second stream replaces the first.
        let secondStream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("New content")
            continuation.finish()
        }

        vm.showStream(secondStream, sourceApp: "Xcode")
        try await Task.sleep(for: .milliseconds(50))

        #expect(vm.explanationText == "New content")
        #expect(vm.sourceAppName == "Xcode")
        #expect(vm.displayState == .complete)
    }

    // MARK: - Error Display

    @Test @MainActor
    func showErrorSetsErrorState() {
        let vm = ExplanationHUDViewModel()
        vm.showError("No text selected")

        #expect(vm.displayState == .error)
        #expect(vm.errorMessage == "No text selected")
        #expect(vm.explanationText == "")
        #expect(vm.isVisible == true)
        #expect(vm.isStreaming == false)
    }

    @Test @MainActor
    func showErrorCancelsActiveStream() async throws {
        let vm = ExplanationHUDViewModel()

        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("Streaming...")
            continuation.onTermination = { _ in }
        }

        vm.showStream(stream, sourceApp: nil)
        try await Task.sleep(for: .milliseconds(50))

        vm.showError("Connection lost")

        #expect(vm.displayState == .error)
        #expect(vm.errorMessage == "Connection lost")
        #expect(vm.explanationText == "")
    }

    // MARK: - Dismiss

    @Test @MainActor
    func dismissResetsToIdle() async throws {
        let vm = ExplanationHUDViewModel()

        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("Some text")
            continuation.finish()
        }

        vm.showStream(stream, sourceApp: "Xcode")
        try await Task.sleep(for: .milliseconds(50))

        vm.dismiss()

        #expect(vm.displayState == .idle)
        #expect(vm.explanationText == "")
        #expect(vm.errorMessage == "")
        #expect(vm.sourceAppName == nil)
        #expect(vm.isVisible == false)
    }

    @Test @MainActor
    func dismissFromErrorResetsToIdle() {
        let vm = ExplanationHUDViewModel()
        vm.showError("Something broke")
        vm.dismiss()

        #expect(vm.displayState == .idle)
        #expect(vm.isVisible == false)
    }

    @Test @MainActor
    func dismissWhileIdleIsNoOp() {
        let vm = ExplanationHUDViewModel()
        vm.dismiss()
        #expect(vm.displayState == .idle)
    }
}
