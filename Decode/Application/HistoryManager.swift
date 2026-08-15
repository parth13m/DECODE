// HistoryManager.swift — Decode Application
//
// Manages the 10 most recent explanation requests and their follow-up
// conversations. Persists to a local JSON file following the same pattern
// as SessionStatePersistence.
//
// ## Design
//
// - In-memory array loaded once at startup, persisted on every mutation.
// - Ordering is by original explanation creation time (newest first).
//   Follow-ups do NOT reorder their parent request.
// - Only successful completions are recorded (no partial/failed/cancelled).
// - Cleared on logout (user's code/responses must not survive account switch).
// - Local only — no backend involvement, no AI calls, no ICU cost.

import Foundation

// MARK: - HistoryPersistence

/// File-based persistence for history requests.
///
/// Uses atomic writes and graceful error handling, consistent with
/// ``SessionStatePersistence``.
enum HistoryPersistence {

    /// The default file URL: `~/Library/Application Support/Decode/history.json`.
    static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Decode", isDirectory: true)
        return appSupport.appendingPathComponent("history.json")
    }

    /// Save history requests to the given file URL.
    ///
    /// Uses atomic write to prevent partial writes on crash or power loss.
    static func save(_ items: [HistoryRequest], to url: URL? = nil) {
        let target = url ?? defaultFileURL
        do {
            // Ensure the parent directory exists.
            let dir = target.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: target, options: .atomic)
        } catch {
            #if DEBUG
            print("[History] Failed to save: \(error)")
            #endif
        }
    }

    /// Load history requests from the given file URL.
    ///
    /// Returns an empty array if the file does not exist or is corrupted.
    static func load(from url: URL? = nil) -> [HistoryRequest] {
        let source = url ?? defaultFileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: source)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([HistoryRequest].self, from: data)
        } catch {
            #if DEBUG
            print("[History] Failed to load (corrupt or incompatible): \(error)")
            #endif
            return []
        }
    }

    /// Delete the history file. Used on logout and in tests.
    static func delete(at url: URL? = nil) {
        let target = url ?? defaultFileURL
        try? FileManager.default.removeItem(at: target)
    }
}

// MARK: - HistoryManager

/// Manages the in-memory history list and persists mutations to disk.
///
/// `@MainActor` to match the existing application state architecture
/// (AppDependencies, coordinators, view models are all MainActor).
/// The JSON file is small (10 items, ~50-200 KB) so synchronous I/O
/// is sub-millisecond — consistent with ``SessionStatePersistence``.
@MainActor
@Observable
final class HistoryManager {

    /// The history items, newest first by original creation time.
    private(set) var items: [HistoryRequest] = []

    /// File URL for persistence. Configurable for testing.
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? HistoryPersistence.defaultFileURL
    }

    // MARK: - Lifecycle

    /// Whether the in-memory items have been mutated since init.
    /// Guards against background restore overwriting a user action.
    private var hasMutated = false

    /// Load history from disk. Called once during app startup.
    func restore() {
        items = HistoryPersistence.load(from: fileURL)
        hasMutated = false
    }

    /// Load history from disk without blocking the main actor.
    ///
    /// File I/O runs on a background thread. The loaded items are
    /// published back to `@MainActor` on completion, but only if no
    /// mutation (e.g., a new explanation recording) has occurred in
    /// the meantime.
    func restoreAsync() async {
        let url = fileURL
        let loaded: [HistoryRequest] = await Task.detached {
            HistoryPersistence.load(from: url)
        }.value

        // Only apply the loaded data if nothing has been recorded yet.
        // If the user somehow triggered an explanation before restore
        // finished, keep the newer in-memory state.
        guard !hasMutated else { return }
        items = loaded
    }

    /// Clear all history and delete the file. Called on logout.
    func clear() {
        items = []
        HistoryPersistence.delete(at: fileURL)
    }

    // MARK: - Recording

    /// Record a successfully completed explanation request.
    ///
    /// Inserts at the front of the list (newest first). If the list
    /// exceeds ``HistoryRequest.maxItemCount``, the oldest item is removed.
    ///
    /// - Returns: The ID of the newly created history request, for use
    ///   when recording follow-ups.
    @discardableResult
    func recordExplanation(
        mode: String,
        originalCode: String,
        explanation: String,
        sourceAppName: String? = nil,
        fileName: String? = nil,
        language: String? = nil,
        explanationProfile: String? = nil,
        customQuestion: String? = nil
    ) -> UUID {
        let request = HistoryRequest(
            id: UUID(),
            createdAt: Date(),
            mode: mode,
            originalCode: originalCode,
            explanation: explanation,
            sourceAppName: sourceAppName,
            fileName: fileName,
            language: language,
            explanationProfile: explanationProfile,
            customQuestion: customQuestion,
            followUps: []
        )
        hasMutated = true
        items.insert(request, at: 0)
        if items.count > HistoryRequest.maxItemCount {
            items.removeLast()
        }
        persist()
        return request.id
    }

    /// Record a successfully completed follow-up on an existing request.
    ///
    /// Appends the follow-up to the parent request's follow-up list.
    /// Does NOT reorder the parent request in the history list.
    func recordFollowUp(
        requestId: UUID,
        question: String,
        answer: String
    ) {
        guard let index = items.firstIndex(where: { $0.id == requestId }) else {
            #if DEBUG
            print("[History] Cannot record follow-up: request \(requestId) not found")
            #endif
            return
        }
        let followUp = HistoryFollowUp(
            id: UUID(),
            createdAt: Date(),
            question: question,
            answer: answer
        )
        items[index].followUps.append(followUp)
        persist()
    }

    /// The most recent history request, if any. This is the active
    /// request for follow-up from the History HUD.
    var activeRequest: HistoryRequest? {
        items.first
    }

    // MARK: - Private

    private func persist() {
        HistoryPersistence.save(items, to: fileURL)
    }
}
