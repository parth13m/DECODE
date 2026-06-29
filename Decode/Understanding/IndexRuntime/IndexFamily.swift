// IndexFamily.swift — IndexRuntime
// DDS-004: Five index families — Entity, Graph, Scope, Predicate, Content
// DAS-007: IL-2 (creation in priority order), IFR-4 (rebuild priority)

import Foundation

/// Identifies one of the five index families.
///
/// DAS-007: Five index families, each serving a distinct access pattern.
/// Construction and rebuild follow priority order (DAS-007 IL-2, IFR-4).
public enum IndexFamily: String, Hashable, Sendable, CaseIterable {
    /// Maps entity → set of (unitID, predicate, tier, status). Priority: highest.
    case entity
    /// Bidirectional relationship traversal. Priority: high.
    case graph
    /// Containment tree with transitive closure. Priority: high.
    case scope
    /// Maps predicate → set of (unitID, subject, tier, status, producer). Priority: moderate.
    case predicate
    /// Term-based text search over text-valued units. Priority: lowest. Deferred index.
    case content

    /// Construction/rebuild priority (lower = higher priority).
    /// DAS-007 IL-2, DDS-004 PR-1.
    public var priority: Int {
        switch self {
        case .entity: return 0
        case .graph: return 1
        case .scope: return 2
        case .predicate: return 3
        case .content: return 4
        }
    }

    /// Whether this family is structural (synchronous, epoch-consistent)
    /// or deferred (may lag by one epoch).
    ///
    /// DDS-004: Entity, Graph, Scope, Predicate are structural.
    /// Content is deferred (DAS-010 IM-4).
    public var isStructural: Bool {
        self != .content
    }

    /// All families in construction priority order.
    public static var constructionOrder: [IndexFamily] {
        allCases.sorted { $0.priority < $1.priority }
    }
}

/// Per-family availability state.
///
/// DDS-004: Each family independently tracks its availability.
/// ```
/// Absent → Building → Available → Rebuilding → Available
///                                → Absent (on corruption or loss)
/// ```
public enum IndexFamilyAvailability: String, Hashable, Sendable {
    /// Not constructed or lost. Queries use DIR scan fallback.
    case absent
    /// Being constructed or rebuilt. Queries use DIR scan fallback.
    case building
    /// Constructed, current, serving indexed queries.
    case available
    /// Being rebuilt due to inconsistency. Prior index available for queries
    /// during rebuild. New index atomically replaces prior on completion.
    case rebuilding

    /// Returns whether transitioning to the given availability is valid.
    public func canTransition(to target: IndexFamilyAvailability) -> Bool {
        switch (self, target) {
        case (.absent, .building): return true
        case (.building, .available): return true
        case (.available, .rebuilding): return true
        case (.available, .absent): return true
        case (.rebuilding, .available): return true
        case (.rebuilding, .absent): return true
        default: return false
        }
    }
}
