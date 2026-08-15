// HUDFramePersistence.swift — Decode Presentation
//
// Shared window frame persistence for HUD panels (History, Explanation).
// Saves and restores NSRect via UserDefaults with screen-visibility validation.

import AppKit

enum HUDFramePersistence {

    /// Identifiers for each HUD's independent frame storage.
    enum HUDIdentifier: String {
        case history = "decodeHistoryHUDFrame"
        case explanation = "decodeExplanationHUDFrame"
    }

    /// Save a window's frame to UserDefaults.
    static func saveFrame(_ frame: NSRect, for hud: HUDIdentifier) {
        let dict: [String: Double] = [
            "x": Double(frame.origin.x),
            "y": Double(frame.origin.y),
            "w": Double(frame.size.width),
            "h": Double(frame.size.height),
        ]
        UserDefaults.standard.set(dict, forKey: hud.rawValue)
    }

    /// Load a previously saved frame, validated against current screen layout.
    ///
    /// Returns `nil` if no frame was saved or if the saved frame is entirely
    /// off-screen (e.g., external display disconnected).
    static func loadFrame(for hud: HUDIdentifier) -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(forKey: hud.rawValue),
              let x = dict["x"] as? Double,
              let y = dict["y"] as? Double,
              let w = dict["w"] as? Double,
              let h = dict["h"] as? Double else {
            return nil
        }

        let frame = NSRect(x: x, y: y, width: w, height: h)
        return isFrameVisible(frame) ? frame : nil
    }

    /// Check whether at least part of the frame is visible on any connected screen.
    private static func isFrameVisible(_ frame: NSRect) -> Bool {
        for screen in NSScreen.screens {
            if frame.intersects(screen.visibleFrame) {
                return true
            }
        }
        return false
    }
}
