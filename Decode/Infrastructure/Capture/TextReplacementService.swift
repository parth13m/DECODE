import AppKit
import os.log

private let replaceLog = Logger(subsystem: "com.decode.replace", category: "replacement")

/// The result of a text replacement attempt.
enum ReplacementResult: Sendable {
    /// Replacement succeeded — paste was sent to the editor.
    case success
    /// Decode is the frontmost app — user needs to switch to their editor.
    case decodeIsFrontmost
    /// CGEvent paste simulation failed.
    case pasteEventFailed
}

/// Replaces the current editor selection with new text via clipboard + ⌘V.
///
/// Uses the same clipboard backup/restore pattern as ``AccessibilityCapture``'s
/// clipboard fallback. The replacement flow:
///
/// 1. Verify the frontmost app is not Decode
/// 2. Backup current clipboard contents
/// 3. Write replacement text to clipboard
/// 4. Simulate ⌘V via CGEvent
/// 5. Wait for the editor to process the paste
/// 6. Restore original clipboard contents
///
/// Requires Accessibility permission (already granted for text capture).
@MainActor
final class TextReplacementService {

    // MARK: - Public

    /// Replace the current selection in the frontmost editor with the given text.
    ///
    /// - Parameter text: The replacement text to paste.
    /// - Returns: The result of the replacement attempt.
    func replaceSelection(with text: String) async -> ReplacementResult {
        // 1. Guard: frontmost app must not be Decode.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier == Bundle.main.bundleIdentifier {
            replaceLog.warning("replacement blocked: Decode is frontmost app")
            return .decodeIsFrontmost
        }

        let pasteboard = NSPasteboard.general

        // 2. Backup current clipboard.
        let savedItems = backupPasteboard(pasteboard)

        // 3. Write replacement text to clipboard.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 4. Simulate ⌘V.
        guard simulatePaste() else {
            replaceLog.warning("replacement failed: CGEvent paste simulation failed")
            restorePasteboard(pasteboard, items: savedItems)
            return .pasteEventFailed
        }

        // 5. Wait for the editor to process the paste command.
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

        // 6. Restore original clipboard.
        restorePasteboard(pasteboard, items: savedItems)

        #if DEBUG
        print("[DIAG_REPLACE] replacement complete, \(text.count) chars pasted")
        #endif

        replaceLog.info("replacement succeeded: \(text.count, privacy: .public) chars")
        return .success
    }

    // MARK: - CGEvent Paste

    /// Simulate a `⌘V` keystroke via CGEvent.
    ///
    /// Virtual key 9 = V. Uses `.privateState` so the event is independent
    /// of the current HID keyboard state — matches the existing `simulateCopy`
    /// pattern in ``AccessibilityCapture``.
    private func simulatePaste() -> Bool {
        let source = CGEventSource(stateID: .privateState)

        // Virtual key 9 = V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        return true
    }

    // MARK: - Clipboard Backup/Restore

    /// Save all pasteboard items so they can be restored after pasting.
    ///
    /// Mirrors ``AccessibilityCapture/backupPasteboard(_:)``.
    private func backupPasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        var backup: [[NSPasteboard.PasteboardType: Data]] = []
        guard let items = pasteboard.pasteboardItems else { return backup }

        for item in items {
            var itemData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    itemData[type] = data
                }
            }
            backup.append(itemData)
        }
        return backup
    }

    /// Restore previously saved pasteboard contents.
    ///
    /// Mirrors ``AccessibilityCapture/restorePasteboard(_:items:)``.
    private func restorePasteboard(
        _ pasteboard: NSPasteboard,
        items: [[NSPasteboard.PasteboardType: Data]]
    ) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        var pasteboardItems: [NSPasteboardItem] = []
        for itemData in items {
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            pasteboardItems.append(item)
        }
        pasteboard.writeObjects(pasteboardItems)
    }
}
