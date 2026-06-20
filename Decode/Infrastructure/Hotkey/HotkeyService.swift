import AppKit

// MARK: - HotkeyService

/// Concrete implementation of ``HotkeyServiceProtocol`` using NSEvent monitors.
///
/// Supports two trigger styles:
/// - **Double-tap modifier**: Tap a single modifier key twice within 300ms.
///   Any non-modifier key pressed between taps cancels the sequence.
///   Multi-modifier combinations are ignored.
/// - **Modifier + key**: Traditional chord binding (e.g., `⌃⇧O`).
///
/// ## Current Bindings
/// - Double-tap Control → `.explainSelection`
/// - Double-tap Option  → `.captureScreenshot`
/// - Double-tap Shift   → `.askSessionQuestion`
/// - `⌃⇧O`             → `.openSession`
///
/// ## Important Limitation
/// `NSEvent.addGlobalMonitorForEvents` is **observe-only** — it cannot prevent
/// the keystroke from reaching the target app.
///
/// ## Threading
/// This service is `@MainActor`-isolated. All monitors deliver callbacks on
/// the main thread.
@MainActor
final class HotkeyService: HotkeyServiceProtocol {

    // MARK: - Chord Bindings (modifier + key)

    /// A traditional hotkey binding: modifier flags + key code → action.
    private struct ChordBinding {
        let modifiers: NSEvent.ModifierFlags
        let keyCode: UInt16
        let action: HotkeyAction
    }

    /// The set of modifier flags we care about when matching chords.
    private static let significantModifiers: NSEvent.ModifierFlags = [
        .command, .shift, .option, .control,
    ]

    // Key code: O = 31
    private static let chordBindings: [ChordBinding] = [
        ChordBinding(modifiers: [.control, .shift], keyCode: 31, action: .openSession),
    ]

    // MARK: - Double-Tap Bindings (modifier-only)

    /// A double-tap binding: tap a single modifier twice → action.
    private struct DoubleTapBinding {
        let modifier: NSEvent.ModifierFlags
        let action: HotkeyAction
    }

    private static let doubleTapBindings: [DoubleTapBinding] = [
        DoubleTapBinding(modifier: .control, action: .explainSelection),
        DoubleTapBinding(modifier: .option, action: .captureScreenshot),
        DoubleTapBinding(modifier: .shift, action: .askSessionQuestion),
    ]

    /// Maximum interval between two taps for a double-tap to register.
    private static let doubleTapWindow: TimeInterval = 0.250

    /// If a character key was pressed within this interval before the first tap,
    /// the double-tap is suppressed. Prevents false triggers during fast typing
    /// (e.g., typing "URL" or "API" with rapid Shift presses).
    private static let typingCooldown: TimeInterval = 0.400

    // MARK: - Double-Tap State Machine

    /// Tracks the state of a pending double-tap sequence.
    ///
    /// ```
    /// idle ──(modifier pressed alone)──→ awaitingSecondTap
    /// awaitingSecondTap ──(same modifier pressed within window)──→ fire + idle
    /// awaitingSecondTap ──(keyDown / different modifier / timeout)──→ idle
    /// ```
    private struct DoubleTapState {
        /// The modifier flag that was pressed on the first tap.
        var pendingModifier: NSEvent.ModifierFlags?
        /// Timestamp of the first tap (modifier key-down).
        var firstTapTime: TimeInterval = 0
        /// Whether the modifier from the first tap has been released.
        var released = false
    }

    private var doubleTapState = DoubleTapState()
    private var doubleTapTimeoutWork: DispatchWorkItem?

    /// Timestamp of the most recent `.keyDown` event. Used to detect active
    /// typing and suppress false-positive double-tap triggers.
    private var lastKeyDownTime: TimeInterval = 0

    // MARK: - Monitor State

    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var continuation: AsyncStream<HotkeyEvent>.Continuation?

    // MARK: - HotkeyServiceProtocol

    func startListening() -> AsyncStream<HotkeyEvent> {
        stopListening()

        let (stream, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        self.continuation = continuation

        // --- keyDown monitors: chord matching + double-tap cancellation ---

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event, source: "global")
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if Self.matchedChordAction(for: event) != nil {
                self.handleKeyDown(event, source: "local")
                return nil  // Consume within our app
            }
            // Still need to cancel double-tap on any keyDown
            self.cancelDoubleTap()
            return event
        }

        // --- flagsChanged monitors: double-tap modifier detection ---

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        #if DEBUG
        print("[DEBUG HotkeyService] monitors registered — globalKey=\(globalKeyMonitor != nil), localKey=\(localKeyMonitor != nil), globalFlags=\(globalFlagsMonitor != nil), localFlags=\(localFlagsMonitor != nil), AXTrusted=\(AXIsProcessTrusted())")
        #endif

        return stream
    }

    func stopListening() {
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        globalKeyMonitor = nil
        localKeyMonitor = nil
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        doubleTapTimeoutWork?.cancel()
        doubleTapTimeoutWork = nil
        doubleTapState = DoubleTapState()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - keyDown Handling

    private func handleKeyDown(_ event: NSEvent, source: String) {
        // Record timestamp for typing-cooldown check.
        lastKeyDownTime = event.timestamp

        // Any keyDown cancels a pending double-tap sequence.
        cancelDoubleTap()

        // Check chord bindings.
        guard let action = Self.matchedChordAction(for: event) else { return }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        #if DEBUG
        print("[DEBUG HotkeyService] \(source): CHORD MATCHED keyCode=\(event.keyCode), action=\(action), sourceApp=\(frontmostApp?.localizedName ?? "nil")")
        #endif

        let hotkeyEvent = HotkeyEvent(
            action: action,
            sourceAppPID: frontmostApp?.processIdentifier,
            sourceAppName: frontmostApp?.localizedName
        )
        continuation?.yield(hotkeyEvent)
    }

    /// Match an NSEvent against chord bindings.
    private static func matchedChordAction(for event: NSEvent) -> HotkeyAction? {
        let eventModifiers = event.modifierFlags.intersection(significantModifiers)
        for binding in chordBindings {
            if event.keyCode == binding.keyCode && eventModifiers == binding.modifiers {
                return binding.action
            }
        }
        return nil
    }

    // MARK: - flagsChanged Handling (Double-Tap State Machine)

    private func handleFlagsChanged(_ event: NSEvent) {
        let currentModifiers = event.modifierFlags.intersection(Self.significantModifiers)

        // Determine which single modifier changed.
        // We only care about events where exactly one significant modifier is active or
        // all modifiers were released (key-up of the last modifier).
        let singleModifier = Self.extractSingleModifier(currentModifiers)

        if let modifier = singleModifier {
            // A single modifier is now pressed (key-down of that modifier).
            handleModifierDown(modifier, timestamp: event.timestamp)
        } else if currentModifiers.isEmpty {
            // All modifiers released — this is the key-up of whatever was held.
            handleModifierUp()
        } else {
            // Multiple modifiers held simultaneously — cancel any pending double-tap.
            cancelDoubleTap()
        }
    }

    private func handleModifierDown(_ modifier: NSEvent.ModifierFlags, timestamp: TimeInterval) {
        if let pending = doubleTapState.pendingModifier {
            // We have a pending first tap. Check if this is the second tap of the same modifier.
            if pending == modifier && doubleTapState.released {
                let elapsed = timestamp - doubleTapState.firstTapTime
                if elapsed <= Self.doubleTapWindow {
                    // Double-tap detected!
                    fireDoubleTap(modifier: modifier)
                    return
                }
            }
            // Different modifier, or same modifier but not released in between,
            // or timed out — reset and treat this as a new first tap.
        }

        // Record as first tap.
        doubleTapState.pendingModifier = modifier
        doubleTapState.firstTapTime = timestamp
        doubleTapState.released = false
        scheduleDoubleTapTimeout()
    }

    private func handleModifierUp() {
        // Mark the pending modifier as released.
        if doubleTapState.pendingModifier != nil {
            doubleTapState.released = true
        }
    }

    private func fireDoubleTap(modifier: NSEvent.ModifierFlags) {
        // Find the binding for this modifier.
        guard let binding = Self.doubleTapBindings.first(where: { $0.modifier == modifier }) else {
            cancelDoubleTap()
            return
        }

        // Suppress if the user was actively typing just before the first tap.
        // This prevents false triggers during fast capital-letter sequences
        // (e.g., typing "URL" or "API") where Shift is pressed rapidly.
        let timeSinceLastKey = doubleTapState.firstTapTime - lastKeyDownTime
        if lastKeyDownTime > 0 && timeSinceLastKey >= 0 && timeSinceLastKey < Self.typingCooldown {
            #if DEBUG
            print("[DEBUG HotkeyService] DOUBLE-TAP SUPPRESSED (typing cooldown) modifier=\(modifier), timeSinceLastKey=\(String(format: "%.0f", timeSinceLastKey * 1000))ms")
            #endif
            cancelDoubleTap()
            return
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        #if DEBUG
        print("[DEBUG HotkeyService] DOUBLE-TAP MATCHED modifier=\(modifier), action=\(binding.action), sourceApp=\(frontmostApp?.localizedName ?? "nil")")
        #endif

        let hotkeyEvent = HotkeyEvent(
            action: binding.action,
            sourceAppPID: frontmostApp?.processIdentifier,
            sourceAppName: frontmostApp?.localizedName
        )
        continuation?.yield(hotkeyEvent)

        // Reset state.
        cancelDoubleTap()
    }

    // MARK: - Double-Tap Timeout

    private func scheduleDoubleTapTimeout() {
        doubleTapTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.cancelDoubleTap()
        }
        doubleTapTimeoutWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.doubleTapWindow,
            execute: work
        )
    }

    private func cancelDoubleTap() {
        doubleTapTimeoutWork?.cancel()
        doubleTapTimeoutWork = nil
        doubleTapState = DoubleTapState()
    }

    // MARK: - Helpers

    /// If exactly one significant modifier flag is set, return it. Otherwise nil.
    private static func extractSingleModifier(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags? {
        let candidates: [NSEvent.ModifierFlags] = [.command, .shift, .option, .control]
        var found: NSEvent.ModifierFlags?
        for candidate in candidates {
            if flags.contains(candidate) {
                if found != nil {
                    // Multiple modifiers — not a single-modifier press.
                    return nil
                }
                found = candidate
            }
        }
        return found
    }

    // Note: No deinit cleanup needed. Under Swift 6 strict concurrency,
    // deinit is nonisolated and cannot access @MainActor-isolated stored
    // properties. Callers must call stopListening() before releasing the
    // service. In practice, HotkeyService lives for the app's lifetime
    // in AppDependencies, so this is a non-issue.
}
