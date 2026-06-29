// FileChangeEvent.swift — UpdateEngine / ChangeDetection
// DDS-007: Change Event — notification that a source artifact has been modified

import Foundation
import DIRCore

/// The type of file-level change detected.
///
/// DDS-007: Change events are file-level notifications.
/// Entity-level comparison happens after frontend re-parse.
public enum FileChangeType: String, Hashable, Sendable {
    /// File content was modified.
    case modified
    /// File was created (new file).
    case created
    /// File was deleted.
    case deleted
}

/// A file-level change event.
///
/// DDS-007: Received from file system monitoring infrastructure.
/// Grouped into change sets for atomic processing.
public struct FileChangeEvent: Hashable, Sendable {
    /// The path of the changed file.
    public let filePath: String

    /// The type of change.
    public let changeType: FileChangeType

    public init(filePath: String, changeType: FileChangeType) {
        self.filePath = filePath
        self.changeType = changeType
    }
}

/// A set of file changes to be processed atomically.
///
/// DDS-007: One or more change events grouped into an atomic processing unit.
/// Content-hash filtering removes unchanged files before entity comparison.
public struct ChangeSet: Sendable {
    /// The file change events in this set.
    public let events: [FileChangeEvent]

    public init(events: [FileChangeEvent]) {
        self.events = events
    }
}

/// The result of processing a change set through the synchronous pipeline.
///
/// DDS-007 OB-1: Change set metrics.
public struct ChangeSetResult: Sendable {
    /// Number of files in the original change set.
    public let totalFiles: Int
    /// Number of files filtered by content-hash comparison (unchanged).
    public let hashFilteredFiles: Int
    /// Number of units directly invalidated.
    public let directInvalidations: Int
    /// Number of units invalidated by cascade propagation.
    public let cascadeInvalidations: Int
    /// Number of T2 units added to deferred queue.
    public let deferredT2Units: Int
    /// Number of synchronous recomputation tickets issued.
    public let syncRecomputationTickets: Int
    /// Whether early termination occurred.
    public let earlyTerminations: Int
    /// The epoch before processing.
    public let epochBefore: Epoch
    /// The epoch after processing.
    public let epochAfter: Epoch
    /// Duration of the pipeline.
    public let duration: TimeInterval

    public init(
        totalFiles: Int,
        hashFilteredFiles: Int,
        directInvalidations: Int,
        cascadeInvalidations: Int,
        deferredT2Units: Int,
        syncRecomputationTickets: Int,
        earlyTerminations: Int,
        epochBefore: Epoch,
        epochAfter: Epoch,
        duration: TimeInterval
    ) {
        self.totalFiles = totalFiles
        self.hashFilteredFiles = hashFilteredFiles
        self.directInvalidations = directInvalidations
        self.cascadeInvalidations = cascadeInvalidations
        self.deferredT2Units = deferredT2Units
        self.syncRecomputationTickets = syncRecomputationTickets
        self.earlyTerminations = earlyTerminations
        self.epochBefore = epochBefore
        self.epochAfter = epochAfter
        self.duration = duration
    }
}
