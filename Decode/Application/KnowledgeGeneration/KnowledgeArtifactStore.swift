// KnowledgeArtifactStore.swift — Knowledge Generation Runtime
//
// Persistent cache for knowledge artifacts produced by the KGR.
//
// Stores job outputs keyed by (jobIdentifier, filePath, contentHash).
// Supports invalidation by file path (hash mismatch) and bulk
// invalidation by workspace.
//
// Persistence: single JSON file at:
//   ~/Library/Application Support/Decode/knowledge/artifacts.json
//
// The artifact store is separate from the DIR (StorageEngine).
// The DIR stores structural facts (T0/T1 units) produced by the pipeline.
// The artifact store caches interpreted knowledge produced by the KGR.

import Foundation

// MARK: - Reading Protocol

/// Read-only access to the artifact store.
///
/// Used by the planner and coordinators to check cache validity
/// without exposing mutation methods.
protocol KnowledgeArtifactStoreReading: Sendable {
    /// Look up a cached artifact.
    ///
    /// Returns `nil` if not cached or if the content hash doesn't match.
    func lookup(
        jobIdentifier: String,
        filePath: String,
        contentHash: String
    ) -> KnowledgeArtifactEntry?

    /// Check whether an artifact exists for the given key.
    func contains(key: KnowledgeCacheKey) -> Bool
}

// MARK: - Artifact Entry

/// A single cached knowledge artifact.
struct KnowledgeArtifactEntry: Codable, Sendable {
    /// The cache key identifying this artifact.
    let key: KnowledgeCacheKey

    /// The encoded artifact data.
    let data: Data

    /// When this artifact was computed.
    let computedAt: Date

    /// Which capability tier produced this artifact.
    let tier: KnowledgeCapabilityTier

    /// The workspace that triggered this artifact's creation.
    let workspaceId: UUID
}

// MARK: - Artifact Store

/// Persistent cache for knowledge artifacts.
///
/// Stores artifacts in memory with incremental disk persistence.
/// Atomic writes prevent partial file corruption on crash.
///
/// ## Thread Safety
/// All public methods are `@MainActor`-isolated, matching the
/// coordinator and manager pattern used throughout Decode.
@MainActor
final class KnowledgeArtifactStore: KnowledgeArtifactStoreReading {

    // MARK: - State

    /// In-memory cache: KnowledgeCacheKey → artifact entry.
    private var cache: [KnowledgeCacheKey: KnowledgeArtifactEntry] = [:]

    /// The file URL for persistence.
    private let persistenceURL: URL

    /// Whether the store has been modified since the last save.
    private var isDirty: Bool = false

    // MARK: - Init

    /// Creates an artifact store with the specified persistence URL.
    ///
    /// - Parameter persistenceURL: Where to persist artifacts.
    ///   Defaults to `~/Library/Application Support/Decode/knowledge/artifacts.json`.
    init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL ?? Self.defaultFileURL
    }

    // MARK: - Reading (KnowledgeArtifactStoreReading)

    /// Look up a cached artifact by job, file path, and content hash.
    ///
    /// Returns `nil` if not cached. The content hash is part of the key,
    /// so stale artifacts (from a prior file version) are never returned.
    nonisolated func lookup(
        jobIdentifier: String,
        filePath: String,
        contentHash: String
    ) -> KnowledgeArtifactEntry? {
        // Note: This is nonisolated for protocol conformance.
        // In production, callers are @MainActor. Thread safety is
        // guaranteed by the caller's isolation context.
        let key = KnowledgeCacheKey(
            jobIdentifier: jobIdentifier,
            filePath: filePath,
            contentHash: contentHash
        )
        return MainActor.assumeIsolated {
            cache[key]
        }
    }

    /// Check whether an artifact exists for the given key.
    nonisolated func contains(key: KnowledgeCacheKey) -> Bool {
        MainActor.assumeIsolated {
            cache[key] != nil
        }
    }

    // MARK: - Writing

    /// Store an artifact from a job output.
    ///
    /// Persists to disk incrementally after each store operation.
    func store(_ output: KnowledgeJobOutput, workspaceId: UUID) {
        let entry = KnowledgeArtifactEntry(
            key: output.key,
            data: output.data,
            computedAt: output.computedAt,
            tier: output.actualTier,
            workspaceId: workspaceId
        )
        cache[output.key] = entry
        isDirty = true
        saveToDisk()
    }

    /// Store a pre-built artifact entry directly.
    func store(entry: KnowledgeArtifactEntry) {
        cache[entry.key] = entry
        isDirty = true
        saveToDisk()
    }

    // MARK: - Invalidation

    /// Invalidate all artifacts for a file path.
    ///
    /// Called when a file changes. The planner will re-evaluate
    /// and create new work items for the changed file.
    func invalidate(filePath: String) {
        let keysToRemove = cache.keys.filter { $0.filePath == filePath }
        guard !keysToRemove.isEmpty else { return }
        for key in keysToRemove {
            cache.removeValue(forKey: key)
        }
        isDirty = true
        saveToDisk()

        #if DEBUG
        print("[KnowledgeArtifactStore] Invalidated \(keysToRemove.count) artifacts for \(filePath)")
        #endif
    }

    /// Invalidate all artifacts for a workspace.
    ///
    /// Called when a workspace is closed or removed.
    func invalidateWorkspace(_ workspaceId: UUID) {
        let keysToRemove = cache.filter { $0.value.workspaceId == workspaceId }.map(\.key)
        guard !keysToRemove.isEmpty else { return }
        for key in keysToRemove {
            cache.removeValue(forKey: key)
        }
        isDirty = true
        saveToDisk()

        #if DEBUG
        print("[KnowledgeArtifactStore] Invalidated \(keysToRemove.count) artifacts for workspace \(workspaceId)")
        #endif
    }

    /// Remove all artifacts. Used in tests or reset scenarios.
    func removeAll() {
        guard !cache.isEmpty else { return }
        cache.removeAll()
        isDirty = true
        saveToDisk()
    }

    // MARK: - Queries

    /// The total number of cached artifacts.
    var count: Int { cache.count }

    /// All cached artifacts for a given job identifier.
    func artifacts(forJob jobIdentifier: String) -> [KnowledgeArtifactEntry] {
        cache.values.filter { $0.key.jobIdentifier == jobIdentifier }
    }

    /// All cached artifacts for a given file path (across all jobs).
    func artifacts(forFile filePath: String) -> [KnowledgeArtifactEntry] {
        cache.values.filter { $0.key.filePath == filePath }
    }

    // MARK: - Persistence

    /// Load artifacts from disk synchronously.
    ///
    /// Retained for tests and fallback. Prefer ``loadFromDiskAsync()``
    /// during startup to avoid blocking the main actor.
    func loadFromDisk() {
        let loaded = Self.readArtifactsFromDisk(url: persistenceURL)
        if let loaded {
            cache = loaded
            isDirty = false
        }
    }

    /// Load artifacts from disk without blocking the main actor.
    ///
    /// File I/O and JSON decoding run on a background thread.
    /// The decoded cache is published back to `@MainActor` on completion.
    func loadFromDiskAsync() async {
        let url = persistenceURL
        let loaded: [KnowledgeCacheKey: KnowledgeArtifactEntry]? = await Task.detached {
            Self.readArtifactsFromDisk(url: url)
        }.value

        if let loaded {
            cache = loaded
            isDirty = false
        }
    }

    /// Pure file I/O: reads and decodes the artifact JSON file.
    ///
    /// `nonisolated static` so it can run from any isolation context.
    /// Returns `nil` if the file does not exist or is corrupted.
    nonisolated private static func readArtifactsFromDisk(
        url: URL
    ) -> [KnowledgeCacheKey: KnowledgeArtifactEntry]? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            #if DEBUG
            print("[KnowledgeArtifactStore] No artifact file found — starting fresh")
            #endif
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let entries = try JSONDecoder().decode([KnowledgeArtifactEntry].self, from: data)
            #if DEBUG
            print("[KnowledgeArtifactStore] Loaded \(entries.count) artifacts from disk")
            #endif
            return Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
        } catch {
            #if DEBUG
            print("[KnowledgeArtifactStore] Failed to load artifacts: \(error) — starting fresh")
            #endif
            return nil
        }
    }

    /// Save artifacts to disk atomically.
    ///
    /// Called after each mutation for crash resilience.
    private func saveToDisk() {
        guard isDirty else { return }

        do {
            // Ensure directory exists.
            let directory = persistenceURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let entries = Array(cache.values)
            let data = try encoder.encode(entries)
            try data.write(to: persistenceURL, options: .atomic)
            isDirty = false
        } catch {
            #if DEBUG
            print("[KnowledgeArtifactStore] Failed to save artifacts: \(error)")
            #endif
        }
    }

    // MARK: - Default URL

    /// Default persistence URL: `~/Library/Application Support/Decode/knowledge/artifacts.json`.
    static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Decode", isDirectory: true)
        return appSupport
            .appendingPathComponent("knowledge", isDirectory: true)
            .appendingPathComponent("artifacts.json")
    }
}
