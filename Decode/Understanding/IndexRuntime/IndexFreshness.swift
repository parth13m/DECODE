// IndexFreshness.swift — IndexRuntime
// DDS-004: PC-3 — Index Freshness Report
// IAG-001 §4: Public protocol, consumed by RetrievalRuntime
// IAG-003 §3.1: async — crosses IndexActor boundary

import Foundation
import DIRCore

/// Provides freshness information for all index families.
///
/// DDS-004 PC-3: For each index family, reports last-update epoch,
/// stale entry count, family availability, and memory footprint estimate.
///
/// IAG-003: All methods are async — they cross the IndexActor boundary.
/// Implemented by IndexActor, consumed by RetrievalRuntime.
public protocol IndexFreshness: Sendable {

    /// Returns the freshness report for all index families.
    ///
    /// DDS-004 PC-3: Always available — reads in-memory metadata, not index content.
    func freshnessReport() async -> FreshnessReport

    /// Returns the freshness report for a specific family.
    func familyFreshness(_ family: IndexFamily) async -> FamilyFreshnessReport

    /// Returns the availability state for a specific family.
    func familyAvailability(_ family: IndexFamily) async -> IndexFamilyAvailability
}
