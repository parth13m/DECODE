// ContentHashMapAccess.swift — StorageEngine
// DDS-008: PC-5 — Content Hash Map Access
// IAG-001 §4: Public protocol, consumed by UpdateEngine
// IAG-003 §3.1: async — crosses StorageActor boundary

import Foundation
import DIRCore

/// Provides access to the per-file content hash map.
///
/// DDS-008 PC-5: Maps tracked file paths to their content hashes.
/// Used by UpdateEngine for reconciliation and change detection.
///
/// IAG-003: All methods are async — they cross the StorageActor boundary.
/// Implemented by StorageActor, consumed by UpdateEngine.
public protocol ContentHashMapAccess: Sendable {

    /// Returns the content hash for a specific file path.
    ///
    /// DDS-008 PC-5: For steady-state change detection.
    func contentHash(for filePath: String) async -> ContentHash?

    /// Returns the full content hash map.
    ///
    /// DDS-008 PC-5: For reconciliation at startup.
    func allContentHashes() async -> [String: ContentHash]

    /// Updates the content hash for a file path.
    ///
    /// DDS-008 PC-5: Called by UpdateEngine after processing content changes.
    func updateContentHash(for filePath: String, hash: ContentHash) async

    /// Removes the content hash for a file path (file deleted).
    func removeContentHash(for filePath: String) async

    /// Returns the number of tracked files.
    func trackedFileCount() async -> Int
}
