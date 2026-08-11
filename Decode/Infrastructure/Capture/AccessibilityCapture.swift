import AppKit
import ApplicationServices
import os.log

private let axLog = Logger(subsystem: "com.decode.ax", category: "capture")

/// Captures selected text from any macOS application.
///
/// Uses a multi-strategy approach:
/// 1. **AX focused element** — `kAXSelectedTextAttribute` on the per-PID or
///    system-wide focused element. Works for native AppKit/SwiftUI apps
///    (TextEdit, Notes, PDF viewers).
/// 2. **AX text markers** — `AXSelectedTextMarkerRange` →
///    `AXStringForTextMarkerRange`. Works for WebKit-based apps (Safari).
/// 3. **AX tree walk** — BFS through the window's AX tree looking for any
///    element with selected text or text markers. Attempted when the focused
///    element is unavailable.
/// 4. **Clipboard fallback** — Simulates `⌘C`, reads the pasteboard, then
///    restores the original clipboard contents. Works for Chromium-based apps
///    (Chrome, VS Code, Cursor, Electron apps) where AX doesn't expose
///    selected text.
///
/// Requires Accessibility permission in System Settings.
final class AccessibilityCapture: SelectionCaptureProtocol {

    /// Roles for single-line text input fields where "selected text" is
    /// likely the field's own content (e.g. a search query), not text the
    /// user highlighted elsewhere on the page. When the focused element
    /// has one of these roles, skip the AX result and let the pipeline
    /// continue to tree walk / clipboard fallback.
    private static let textInputRoles: Set<String> = [
        "AXTextField",
        "AXSearchField",
        "AXComboBox",
    ]

    // MARK: - SelectionCaptureProtocol

    func captureSelection(fromPID pid: pid_t) async throws -> SelectionCaptureResult? {
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "unknown"
        axLog.info("captureSelection — PID=\(pid, privacy: .public), app=\(appName, privacy: .public)")

        guard hasAccessibilityPermission() else {
            axLog.warning("capture failed: accessibility permission denied")
            return nil
        }

        // Primary: AX-based capture (native apps, Safari).
        if let axResult = readSelectedText(fromPID: pid), !axResult.text.isEmpty {
            #if DEBUG
            axLog.debug("DIAG strategy=AX, len=\(axResult.text.count, privacy: .public)")
            #endif
            axLog.info("captured \(axResult.text.count, privacy: .public) chars via AX from \(appName, privacy: .public)")
            return SelectionCaptureResult(
                text: axResult.text,
                sourceApplicationName: appName,
                selectedRange: axResult.selectedRange
            )
        }

        // Fallback: clipboard-based capture (Chrome, VS Code, Electron apps).
        if let text = await captureViaClipboard(), !text.isEmpty {
            #if DEBUG
            axLog.debug("DIAG strategy=clipboard, len=\(text.count, privacy: .public)")
            #endif
            axLog.info("captured \(text.count, privacy: .public) chars via clipboard from \(appName, privacy: .public)")
            return SelectionCaptureResult(text: text, sourceApplicationName: appName)
        }

        axLog.warning("capture failed: no text from AX or clipboard for \(appName, privacy: .public)")
        return nil
    }

    func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Clipboard Fallback

    /// Capture selected text by simulating `⌘C` and reading the pasteboard.
    ///
    /// Saves current clipboard contents, posts the copy keystroke via CGEvent,
    /// reads the new clipboard text, then restores the original contents.
    /// Used when AX-based capture fails (Chrome, VS Code, Electron apps).
    private func captureViaClipboard() async -> String? {
        let pasteboard = NSPasteboard.general

        let previousChangeCount = pasteboard.changeCount
        let savedItems = backupPasteboard(pasteboard)

        // Brief delay to let the hotkey's modifier keys release before posting ⌘C.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        guard simulateCopy() else {
            axLog.warning("clipboard fallback: failed to post ⌘C via CGEvent")
            return nil
        }

        // Wait for the target app to process the copy command.
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

        guard pasteboard.changeCount != previousChangeCount else {
            restorePasteboard(pasteboard, items: savedItems)
            return nil
        }

        let copiedText = readStringFromPasteboard(pasteboard)

        restorePasteboard(pasteboard, items: savedItems)

        return copiedText
    }

    /// Read a string from the pasteboard, trying multiple strategies.
    ///
    /// Strategy 1: Well-known UTI types for plain text.
    /// Strategy 2: Raw data decode from non-excluded types.
    private func readStringFromPasteboard(_ pasteboard: NSPasteboard) -> String? {
        // Strategy 1: Well-known text UTI types.
        let textTypes: [NSPasteboard.PasteboardType] = [
            .string,                                                        // public.utf8-plain-text
            NSPasteboard.PasteboardType("public.utf16-plain-text"),
            NSPasteboard.PasteboardType("public.utf16-external-plain-text"),
            NSPasteboard.PasteboardType("public.plain-text"),
            NSPasteboard.PasteboardType("NSStringPboardType"),
            NSPasteboard.PasteboardType("public.text"),
        ]

        for type in textTypes {
            if let text = pasteboard.string(forType: type), !text.isEmpty {
                return text
            }
        }

        // Strategy 2: Brute-force — try every non-excluded type with multiple
        // text encodings. Catches apps using non-standard pasteboard types.
        guard let items = pasteboard.pasteboardItems else { return nil }

        let encodings: [(String.Encoding, String)] = [
            (.utf8, "UTF-8"),
            (.utf16, "UTF-16"),
            (.utf16LittleEndian, "UTF-16LE"),
            (.utf16BigEndian, "UTF-16BE"),
        ]

        // Types that contain metadata, not user-selected text.
        let excludedTypes: Set<String> = [
            "code/file-list",
            "public.file-url",
            "public.url",
            "com.apple.pasteboard.promised-file-url",
        ]

        for item in items {
            for type in item.types {
                if excludedTypes.contains(type.rawValue) { continue }
                if type.rawValue.hasPrefix("dyn.") { continue }
                guard let data = item.data(forType: type), !data.isEmpty else { continue }

                for (encoding, _) in encodings {
                    if let text = String(data: data, encoding: encoding),
                       !text.isEmpty,
                       text.count > 1
                    {
                        let nullCount = data.filter { $0 == 0 }.count
                        let nullRatio = Double(nullCount) / Double(data.count)
                        if encoding == .utf8 && nullRatio > 0.1 { continue }

                        return text
                    }
                }
            }
        }

        return nil
    }

    /// Simulate a `⌘C` keystroke via CGEvent.
    ///
    /// Uses `.privateState` so the event is independent of the current HID
    /// keyboard state — the hotkey's modifier keys are not inherited.
    private func simulateCopy() -> Bool {
        let source = CGEventSource(stateID: .privateState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        return true
    }

    /// Save all pasteboard items so they can be restored after reading the copy.
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

    // MARK: - AX Capture

    /// Read selected text from the specified application using Accessibility APIs.
    ///
    /// Tries three strategies in order:
    /// 1. Focused element via per-PID app element or system-wide element
    /// 2. Text marker conversion (Safari/WebKit)
    /// 3. BFS tree walk to find any element with selected text
    ///
    /// Returns both the text and (when available) the character range of the
    /// selection within the focused AX element's text.
    private func readSelectedText(fromPID pid: pid_t) -> (text: String, selectedRange: (location: Int, length: Int)?)? {
        let appElement = AXUIElementCreateApplication(pid)

        // Step 1: Get focused UI element.
        var focusedValue: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        if focusedError != .success || focusedValue == nil {
            // Fallback: system-wide element.
            let systemWide = AXUIElementCreateSystemWide()
            let sysError = AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focusedValue
            )
            if sysError != .success || focusedValue == nil {
                // Last resort: walk the AX tree (no range data available).
                if let text = readSelectedTextByTreeWalk(appElement: appElement) {
                    return (text: text, selectedRange: nil)
                }
                return nil
            }
        }

        let focusedUIElement = focusedValue as! AXUIElement

        // Read the role of the focused element to detect text input fields.
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(
            focusedUIElement,
            kAXRoleAttribute as CFString,
            &roleRef
        )
        let role = roleRef as? String

        #if DEBUG
        let diag = axDiagnostics(for: focusedUIElement)
        axLog.debug("DIAG focused — role=\(diag.role, privacy: .public) subrole=\(diag.subrole, privacy: .public) title=\(diag.title, privacy: .public)")
        #endif

        let isTextInput = role.map { Self.textInputRoles.contains($0) } ?? false

        // Try standard kAXSelectedTextAttribute.
        var selectedTextValue: CFTypeRef?
        let selectedError = AXUIElementCopyAttributeValue(
            focusedUIElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        )

        if selectedError == .success, let textRef = selectedTextValue, let text = textRef as? String {
            if isTextInput {
                // Text input fields (search boxes, address bars) often hold
                // their own content as "selected text" even when the user
                // highlighted text elsewhere on the page. Skip and let the
                // pipeline continue to tree walk / clipboard fallback.
                #if DEBUG
                let preview = String(text.prefix(100))
                axLog.debug("DIAG skipping text input — role=\(role ?? "nil", privacy: .public) len=\(text.count, privacy: .public) preview=\(preview, privacy: .public)")
                #endif
            } else {
                #if DEBUG
                let preview = String(text.prefix(100))
                axLog.debug("DIAG accepted AX text — role=\(role ?? "nil", privacy: .public) len=\(text.count, privacy: .public) preview=\(preview, privacy: .public)")
                #endif

                // Query AX selected text range for position data.
                var selectedRange: (location: Int, length: Int)? = nil
                var rangeRef: CFTypeRef?
                let rangeErr = AXUIElementCopyAttributeValue(
                    focusedUIElement,
                    kAXSelectedTextRangeAttribute as CFString,
                    &rangeRef
                )
                if rangeErr == .success, let rangeValue = rangeRef {
                    var cfRange = CFRange(location: 0, length: 0)
                    if AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange) {
                        selectedRange = (location: cfRange.location, length: cfRange.length)
                    }
                }

                return (text: text, selectedRange: selectedRange)
            }
        }

        // Fallback: text markers (Safari/WebKit AXWebArea elements, no range data).
        if let text = readSelectedTextViaMarkers(from: focusedUIElement) {
            return (text: text, selectedRange: nil)
        }
        return nil
    }

    // MARK: - Text Marker Fallback (Safari / WebKit)

    /// Extract selected text from a WebKit AXWebArea element using text markers.
    ///
    /// Safari exposes selection via `AXSelectedTextMarkerRange` instead of
    /// `kAXSelectedTextAttribute`. The marker range is converted to a string
    /// via the parameterized attribute `AXStringForTextMarkerRange`.
    private func readSelectedTextViaMarkers(from element: AXUIElement) -> String? {
        var markerRangeRef: CFTypeRef?
        let markerErr = AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextMarkerRange" as CFString,
            &markerRangeRef
        )

        guard markerErr == .success, let markerRange = markerRangeRef else {
            return nil
        }

        var stringRef: CFTypeRef?
        let stringErr = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXStringForTextMarkerRange" as CFString,
            markerRange,
            &stringRef
        )

        guard stringErr == .success, let resultRef = stringRef, let text = resultRef as? String else {
            return nil
        }

        return text
    }

    // MARK: - AX Tree Walk Fallback

    /// Walk the AX tree to find an element with selected text.
    ///
    /// Used when the focused element is unavailable (some Chromium-based apps).
    /// Navigates: app → focused window → BFS children up to depth 8.
    private func readSelectedTextByTreeWalk(appElement: AXUIElement) -> String? {
        var windowRef: CFTypeRef?
        let windowErr = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        )
        guard windowErr == .success, let window = windowRef else {
            return nil
        }

        return searchForSelectedText(in: window as! AXUIElement, maxDepth: 8)
    }

    /// BFS through the AX element tree looking for an element with selected text.
    private func searchForSelectedText(in root: AXUIElement, maxDepth: Int) -> String? {
        struct QueueEntry {
            let element: AXUIElement
            let depth: Int
        }

        var queue: [QueueEntry] = [QueueEntry(element: root, depth: 0)]
        var visited = 0

        while !queue.isEmpty {
            let entry = queue.removeFirst()
            visited += 1

            if visited > 200 { break }

            let element = entry.element

            // Check node role — skip text input fields whose "selected
            // text" is their own content (e.g. a search query), not
            // user-highlighted page text.
            var nodeRoleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(
                element,
                kAXRoleAttribute as CFString,
                &nodeRoleRef
            )
            let nodeRole = nodeRoleRef as? String
            let isTextInput = nodeRole.map { Self.textInputRoles.contains($0) } ?? false

            // Try standard AXSelectedText.
            var selTextRef: CFTypeRef?
            let selTextErr = AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                &selTextRef
            )
            if selTextErr == .success, let text = selTextRef as? String, !text.isEmpty {
                if isTextInput {
                    #if DEBUG
                    let preview = String(text.prefix(100))
                    axLog.debug("DIAG tree walk skipping text input — role=\(nodeRole ?? "nil", privacy: .public) len=\(text.count, privacy: .public) preview=\(preview, privacy: .public)")
                    #endif
                } else {
                    #if DEBUG
                    let preview = String(text.prefix(100))
                    axLog.debug("DIAG tree walk accepted — role=\(nodeRole ?? "nil", privacy: .public) len=\(text.count, privacy: .public) preview=\(preview, privacy: .public)")
                    #endif
                    return text
                }
            }

            // Try text markers.
            if let text = readSelectedTextViaMarkers(from: element), !text.isEmpty {
                return text
            }

            // Enqueue children.
            if entry.depth < maxDepth {
                var childrenRef: CFTypeRef?
                let childErr = AXUIElementCopyAttributeValue(
                    element,
                    kAXChildrenAttribute as CFString,
                    &childrenRef
                )
                if childErr == .success, let children = childrenRef as? [AXUIElement] {
                    for child in children {
                        queue.append(QueueEntry(element: child, depth: entry.depth + 1))
                    }
                }
            }
        }

        return nil
    }

    // MARK: - Diagnostics

    #if DEBUG
    /// Read AX role, subrole, and title for diagnostic logging.
    private func axDiagnostics(for element: AXUIElement) -> (role: String, subrole: String, title: String) {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? "nil"

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = (subroleRef as? String) ?? "nil"

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? "nil"

        return (role, subrole, title)
    }
    #endif

    // MARK: - AXError Descriptions

    private func axErrorName(_ error: AXError) -> String {
        switch error {
        case .success:                            return "success"
        case .failure:                            return "failure"
        case .illegalArgument:                    return "illegalArgument"
        case .invalidUIElement:                   return "invalidUIElement"
        case .invalidUIElementObserver:           return "invalidUIElementObserver"
        case .cannotComplete:                     return "cannotComplete"
        case .attributeUnsupported:               return "attributeUnsupported"
        case .actionUnsupported:                  return "actionUnsupported"
        case .notificationUnsupported:            return "notificationUnsupported"
        case .notImplemented:                     return "notImplemented"
        case .notificationAlreadyRegistered:      return "notificationAlreadyRegistered"
        case .notificationNotRegistered:          return "notificationNotRegistered"
        case .apiDisabled:                        return "apiDisabled"
        case .noValue:                            return "noValue"
        case .parameterizedAttributeUnsupported:  return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision:                 return "notEnoughPrecision"
        @unknown default:                         return "unknown(\(error.rawValue))"
        }
    }
}
