// Grounding.swift — DIRCore
// DAS-002: I-GND-1 (terminates at source), I-GND-2 (finite, acyclic), I-GND-3 (cascade invalidation)
// DAS-002: I-GND-4 (traversable)

import Foundation

/// A position within a source file for direct grounding.
public struct SourcePosition: Hashable, Codable, Sendable {
    /// Path to the source file.
    public let filePath: String

    /// Start line (1-based, inclusive).
    public let startLine: Int

    /// End line (1-based, inclusive). May equal startLine for single-line grounding.
    public let endLine: Int

    /// The content hash of the source file at the time of extraction.
    public let fileVersion: ContentHash

    public init(filePath: String, startLine: Int, endLine: Int, fileVersion: ContentHash) {
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.fileVersion = fileVersion
    }
}

/// The evidence chain connecting an atomic unit to its source material.
///
/// Every grounding chain is finite, acyclic, and terminates at source material
/// within a bounded number of steps (DAS-002 I-GND-2).
///
/// Three grounding types per DAS-002 I-GND-1:
/// - **Direct**: extracted from a specific position in a specific source file.
/// - **Derived**: derived from other units (which have their own grounding, recursively).
/// - **Inferred**: produced by semantic inference from input units plus an inference method.
public enum GroundingChain: Hashable, Codable, Sendable {
    /// Extracted from a specific source position.
    case direct(SourcePosition)

    /// Derived from other units. The chain continues through these units.
    case derived([UnitIdentifier])

    /// Produced by semantic inference from input units using a named method.
    case inferred(inputUnits: [UnitIdentifier], method: String)
}
