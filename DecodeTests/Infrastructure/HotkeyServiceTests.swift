import Foundation
import Testing
@testable import Decode

/// Tests for ``HotkeyService``.
///
/// These tests verify the service's lifecycle behavior: idempotent start/stop,
/// proper cleanup, and stream termination. Actual key event simulation requires
/// a running NSApplication event loop and Accessibility permissions, so
/// event-matching logic is tested through the protocol contract and stream
/// behavior rather than synthetic NSEvent injection.
@Suite(.serialized)
struct HotkeyServiceTests {

    @Test @MainActor
    func startListeningReturnsStream() {
        let service = HotkeyService()
        let stream = service.startListening()

        // Stream should be a valid AsyncStream (non-nil type check via usage)
        // We can't easily inject key events without an event loop, but we can
        // verify the stream terminates cleanly when we stop.
        service.stopListening()

        // Verify we can iterate the terminated stream without hanging
        Task {
            for await _ in stream {
                // Should not receive any events
                Issue.record("Unexpected event received after stopListening()")
            }
        }
    }

    @Test @MainActor
    func stopListeningIsIdempotent() {
        let service = HotkeyService()

        // Calling stop without start should not crash
        service.stopListening()
        service.stopListening()
    }

    @Test @MainActor
    func startListeningTwiceReplacesStream() async {
        let service = HotkeyService()

        let firstStream = service.startListening()
        let secondStream = service.startListening()

        // First stream should have been terminated by the second startListening call
        var firstStreamEnded = false
        for await _ in firstStream {
            Issue.record("First stream should not emit events after replacement")
        }
        firstStreamEnded = true
        #expect(firstStreamEnded)

        service.stopListening()

        // Second stream should also terminate
        var secondStreamEnded = false
        for await _ in secondStream {
            Issue.record("Second stream should not emit events after stopListening")
        }
        secondStreamEnded = true
        #expect(secondStreamEnded)
    }

    @Test @MainActor
    func stopFinishesStreamCleanly() async {
        let service = HotkeyService()
        let stream = service.startListening()

        service.stopListening()

        // Iterating a finished stream should return immediately
        var count = 0
        for await _ in stream {
            count += 1
        }
        #expect(count == 0)
    }
}
