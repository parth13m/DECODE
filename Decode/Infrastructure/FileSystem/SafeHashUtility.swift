import Foundation

/// Streaming SHA-256 hash computation using CryptoKit.
///
/// Reads files in 64KB chunks to minimize memory overhead.
/// Never loads the entire file into memory at once.
///
/// Implemented in Phase 4.
// struct SafeHashUtility { }
