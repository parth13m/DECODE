// ContentHash.swift — DIRCore
// IAG-002: TC-13 — SHA-256 digests stored as 32-byte values; hash type defined in DIRCore
// DAS-002: I-VER-3 — content-addressed, not counter-based

import Foundation
import CryptoKit

/// SHA-256 content hash for staleness detection and change identification.
///
/// Content-addressed: identical content produces identical hashes.
/// Stored as 32 raw bytes.
public struct ContentHash: Hashable, Codable, Sendable {
    /// The 32-byte SHA-256 digest.
    public let bytes: [UInt8]

    /// Computes a SHA-256 hash of the given data.
    public init(of data: Data) {
        let digest = SHA256.hash(data: data)
        self.bytes = Array(digest)
    }

    /// Creates a ContentHash from raw bytes.
    /// - Precondition: `bytes` must be exactly 32 bytes.
    public init(bytes: [UInt8]) {
        precondition(bytes.count == 32, "ContentHash requires exactly 32 bytes (SHA-256)")
        self.bytes = bytes
    }
}

extension ContentHash: CustomStringConvertible {
    public var description: String {
        let hex = bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)..."
    }
}
