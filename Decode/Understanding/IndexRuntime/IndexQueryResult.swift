// IndexQueryResult.swift — IndexRuntime
// DDS-004 PC-1: Query results with fallback notification
// DDS-004 RI-6: DIR scan fallback when family unavailable

import Foundation
import DIRCore

/// The result of an index query, including whether fallback was used.
///
/// DDS-004 PC-1: When an index family is unavailable, the Index Runtime
/// falls back to DIR scan. The caller is notified that fallback is in effect.
public struct IndexQueryResult<Entry: Sendable>: Sendable {
    /// The matching entries.
    public let entries: [Entry]

    /// Whether DIR scan fallback was used instead of the index.
    /// DDS-004 RI-6: Callers can distinguish indexed vs. fallback results.
    public let usedFallback: Bool

    public init(entries: [Entry], usedFallback: Bool) {
        self.entries = entries
        self.usedFallback = usedFallback
    }
}

// MARK: — Freshness Report

/// Per-family freshness report.
///
/// DDS-004 PC-3: Reports last-update epoch, stale entry count,
/// family availability, and memory footprint estimate.
public struct FamilyFreshnessReport: Sendable {
    /// The index family this report describes.
    public let family: IndexFamily

    /// The most recent epoch at which this family was updated.
    public let lastUpdateEpoch: Epoch?

    /// Entries referencing invalidated or superseded units not yet reflected.
    /// Always zero for structural indexes at the committed epoch.
    /// Meaningful only for the Content Index (DDS-004 PC-3).
    public let staleEntryCount: Int

    /// The current availability state.
    public let availability: IndexFamilyAvailability

    /// Approximate memory footprint in bytes.
    public let memoryFootprintBytes: Int

    /// Number of entries in this family.
    public let entryCount: Int

    public init(
        family: IndexFamily,
        lastUpdateEpoch: Epoch?,
        staleEntryCount: Int,
        availability: IndexFamilyAvailability,
        memoryFootprintBytes: Int,
        entryCount: Int
    ) {
        self.family = family
        self.lastUpdateEpoch = lastUpdateEpoch
        self.staleEntryCount = staleEntryCount
        self.availability = availability
        self.memoryFootprintBytes = memoryFootprintBytes
        self.entryCount = entryCount
    }
}

/// Aggregate freshness report for all families.
///
/// DDS-004 PC-3: The full freshness report.
public struct FreshnessReport: Sendable {
    /// Per-family reports.
    public let families: [IndexFamily: FamilyFreshnessReport]

    public init(families: [IndexFamily: FamilyFreshnessReport]) {
        self.families = families
    }
}

// MARK: — Batch Update Result

/// Result of a batch index update.
///
/// DDS-004 PC-4: Reports which families were updated successfully
/// and which failed (triggering rebuild).
public struct BatchUpdateResult: Sendable {
    /// Families that updated successfully.
    public let updatedFamilies: Set<IndexFamily>

    /// Families that failed and were marked for rebuild.
    public let failedFamilies: [IndexFamily: String]

    /// The epoch of the change batch that was processed.
    public let epoch: Epoch

    public init(updatedFamilies: Set<IndexFamily>, failedFamilies: [IndexFamily: String], epoch: Epoch) {
        self.updatedFamilies = updatedFamilies
        self.failedFamilies = failedFamilies
        self.epoch = epoch
    }

    /// Whether all structural families updated successfully.
    public var allStructuralSucceeded: Bool {
        IndexFamily.allCases
            .filter(\.isStructural)
            .allSatisfy { updatedFamilies.contains($0) || !failedFamilies.keys.contains($0) }
    }
}
