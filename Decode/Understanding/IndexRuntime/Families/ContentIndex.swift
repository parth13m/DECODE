// ContentIndex.swift — IndexRuntime
// DDS-004: Content Index — term-based text search over text-valued units
// DAS-010 IM-4: Deferred index, max one epoch behind
// DDS-004 RI-8: Bounded staleness

import Foundation
import DIRCore

/// A deferred update to the Content Index.
///
/// DDS-004: During synchronous pipeline execution, text-valued unit changes
/// are added to a deferred update queue.
enum ContentDeferredUpdate: Sendable {
    /// A text-valued unit was created or superseded (add its terms).
    case add(unitId: UnitIdentifier, subject: UnitSubject, predicate: PredicateIdentifier, text: String)
    /// A unit was invalidated, superseded, or garbage-collected (remove its terms).
    case remove(unitId: UnitIdentifier)
}

/// The Content Index data structure.
///
/// DDS-004: Inverted index mapping search terms to units containing those terms.
/// Deferred index — updates are processed asynchronously after epoch advancement.
///
/// Construction: O(T) scan of text-valued units with tokenization.
/// Memory: ~8 MB at alpha scale (~4,000 T2 text units, ~1 KB avg text).
struct ContentIndex: Sendable {

    /// Maps lowercase term → set of entries referencing units containing that term.
    private var termIndex: [String: Set<ContentIndexEntry>]

    /// Maps unit ID → set of terms indexed for that unit (for efficient removal).
    private var unitTerms: [UnitIdentifier: Set<String>]

    /// Total entry count (term→unit mappings).
    private(set) var count: Int

    init() {
        self.termIndex = [:]
        self.unitTerms = [:]
        self.count = 0
    }

    // MARK: — Query

    /// Returns all entries matching the given search term.
    func query(term: String) -> [ContentIndexEntry] {
        let normalized = term.lowercased()
        return Array(termIndex[normalized, default: []])
    }

    /// Returns entries matching all of the given terms (conjunction).
    func query(terms: [String]) -> [ContentIndexEntry] {
        guard let first = terms.first else { return [] }
        var result = Set(query(term: first))
        for term in terms.dropFirst() {
            result.formIntersection(query(term: term))
        }
        return Array(result)
    }

    // MARK: — Mutation

    /// Indexes a text-valued unit by tokenizing its text content.
    mutating func addUnit(
        unitId: UnitIdentifier,
        subject: UnitSubject,
        predicate: PredicateIdentifier,
        text: String
    ) {
        let terms = tokenize(text)
        let entry = ContentIndexEntry(unitId: unitId, subject: subject, predicate: predicate)
        var unitTermSet: Set<String> = []

        for term in terms {
            let inserted = termIndex[term, default: []].insert(entry).inserted
            if inserted { count += 1 }
            unitTermSet.insert(term)
        }

        unitTerms[unitId] = unitTermSet
    }

    /// Removes all entries for the given unit ID.
    mutating func removeUnit(_ unitId: UnitIdentifier) {
        guard let terms = unitTerms.removeValue(forKey: unitId) else { return }
        for term in terms {
            guard var set = termIndex[term] else { continue }
            let before = set.count
            set = set.filter { $0.unitId != unitId }
            count -= (before - set.count)
            if set.isEmpty {
                termIndex.removeValue(forKey: term)
            } else {
                termIndex[term] = set
            }
        }
    }

    /// Estimated memory footprint in bytes.
    var estimatedMemoryBytes: Int {
        // Rough estimate: each term→entry mapping ~64 bytes + term storage
        count * 64
    }

    /// Removes all entries.
    mutating func clear() {
        termIndex.removeAll()
        unitTerms.removeAll()
        count = 0
    }

    // MARK: — Tokenization

    /// Tokenizes text into lowercase terms for indexing.
    ///
    /// Simple whitespace + punctuation tokenizer. Filters terms shorter than 2 characters.
    private func tokenize(_ text: String) -> Set<String> {
        let components = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        return Set(components)
    }
}
