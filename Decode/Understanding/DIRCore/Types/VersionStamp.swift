// VersionStamp.swift — DIRCore
// DAS-002: I-VER-1 (records source version), I-VER-2 (staleness detection)
// DAS-002: I-VER-3 (content-addressed), I-VER-4 (granular to source artifact)

import Foundation

/// Records the version of source material a unit was derived from.
///
/// Content-addressed, not counter-based: identical content produces the same version (I-VER-3).
/// Granular to the source artifact — a unit about a function in file X carries
/// file X's version, not the entire repository version (I-VER-4).
///
/// For source-extracted units: single content hash of the source file.
/// For derived units: the set of source content hashes from the grounding chain.
public struct VersionStamp: Hashable, Codable, Sendable {
    /// The content hashes of all source files this unit ultimately derives from.
    /// Single-element for source-extracted units; multiple for derived units.
    public let sourceHashes: Set<ContentHash>

    public init(sourceHashes: Set<ContentHash>) {
        self.sourceHashes = sourceHashes
    }

    /// Convenience for source-extracted units grounded to a single file.
    public init(singleSource hash: ContentHash) {
        self.sourceHashes = [hash]
    }
}
