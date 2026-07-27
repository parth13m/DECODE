import Foundation

/// The action triggered by a global hotkey press.
enum HotkeyAction: Sendable {
    /// User pressed the "explain selection" hotkey.
    case explainSelection
    /// User pressed the "screenshot capture" hotkey.
    case captureScreenshot
    /// User pressed the "session question" hotkey.
    case askSessionQuestion
    /// User pressed the "open session" hotkey.
    case openSession
    /// User pressed the "open workspace" hotkey (⌃⇧P — directory selection).
    case openWorkspace
}

/// A hotkey event bundling the action with context about the source application.
///
/// The source app information is captured synchronously in the hotkey callback
/// (before any async scheduling) to avoid race conditions where the frontmost
/// app changes before the coordinator can read it.
struct HotkeyEvent: Sendable {
    /// The hotkey action that was triggered.
    let action: HotkeyAction
    /// The PID of the frontmost application at the moment the hotkey was pressed.
    let sourceAppPID: pid_t?
    /// The localized name of the frontmost application at the moment the hotkey was pressed.
    let sourceAppName: String?
}

/// Defines the contract for registering and handling global hotkeys.
///
/// Global hotkeys allow Decode to respond to key combinations even when
/// the app is not in the foreground. Used by Selection Mode and Screenshot Mode.
protocol HotkeyServiceProtocol: Sendable {

    /// Register global hotkeys and return a stream of triggered events.
    ///
    /// The stream emits a ``HotkeyEvent`` each time the user presses one
    /// of the registered hotkey combinations. Each event includes the
    /// source application context captured at the moment of the key press.
    @MainActor func startListening() -> AsyncStream<HotkeyEvent>

    /// Unregister all global hotkeys.
    @MainActor func stopListening()
}
