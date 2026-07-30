// SessionState.swift — Decode Application
//
// Lightweight model for transient application session state that survives restart.
//
// ## Separation of Concerns
//
// - **Workspace** (database): Persistent history/bookmarks. Every workspace ever
//   created lives in the `workspaces` table. Closing a workspace does NOT delete
//   its database record — the record serves as a historical bookmark for future
//   "Recent Workspaces" or "Reopen" features.
//
// - **SessionState** (this file, JSON): Transient runtime state. Tracks which
//   workspaces were open, which was active, and which was pinned. Written to disk
//   when the open-workspace set changes and on app termination. Read once on
//   launch, then discarded. If the file is missing or corrupt, the app starts
//   with a clean session (no workspaces restored).
//
// This separation ensures that `closeWorkspace()` is a lightweight in-memory
// operation (remove from dictionary, save session state) without database writes,
// while `restoreWorkspaces()` only restores the workspaces the user actually had
// open — not every workspace they ever created.

import Foundation

/// Transient application state that survives restart.
///
/// Written to `~/Library/Application Support/Decode/session-state.json`
/// when the open-workspace set changes and on app termination. Read once
/// on launch to determine which workspaces to restore.
struct SessionState: Codable, Equatable, Sendable {

    /// Workspace IDs that were open (in-memory) when the state was last saved.
    let openWorkspaceIDs: [UUID]

    /// Which workspace was active (selected in the sidebar).
    let activeWorkspaceID: UUID?

    /// Which workspace was pinned, if any.
    let pinnedWorkspaceID: UUID?
}

// MARK: - Persistence

/// File-based persistence for ``SessionState``.
///
/// Uses atomic writes and JSONDecoder for safe, crash-resilient I/O.
/// All methods are synchronous — the data is a handful of UUIDs,
/// serialization is sub-millisecond.
enum SessionStatePersistence {

    /// The default file URL: `~/Library/Application Support/Decode/session-state.json`.
    static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Decode", isDirectory: true)
        return appSupport.appendingPathComponent("session-state.json")
    }

    /// Save session state to the given file URL.
    ///
    /// Uses atomic write to prevent partial writes on crash or power loss.
    static func save(_ state: SessionState, to url: URL? = nil) {
        let target = url ?? defaultFileURL
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: target, options: .atomic)
        } catch {
            #if DEBUG
            print("[SessionState] Failed to save: \(error)")
            #endif
        }
    }

    /// Load session state from the given file URL.
    ///
    /// Returns `nil` if the file does not exist or is corrupted.
    /// A `nil` result means "first launch" or "clean slate" — restore no workspaces.
    static func load(from url: URL? = nil) -> SessionState? {
        let source = url ?? defaultFileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: source)
            return try JSONDecoder().decode(SessionState.self, from: data)
        } catch {
            #if DEBUG
            print("[SessionState] Failed to load (corrupt or incompatible): \(error)")
            #endif
            return nil
        }
    }

    /// Delete the session state file. Used in tests or reset scenarios.
    static func delete(at url: URL? = nil) {
        let target = url ?? defaultFileURL
        try? FileManager.default.removeItem(at: target)
    }
}
