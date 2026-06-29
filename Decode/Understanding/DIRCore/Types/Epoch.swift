// Epoch.swift — DIRCore
// DAS-010: WR-1 (monotonically increasing), WR-3 (atomic advancement)
// DDS-002: R6 — DIR runtime owns the epoch counter exclusively

import Foundation

/// Monotonically increasing counter identifying a consistent DIR state.
///
/// Advanced atomically after synchronous pipeline completion.
/// Consumer reads always observe the committed epoch.
public struct Epoch: Hashable, Codable, Sendable, Comparable {
    public let value: UInt64

    public init(value: UInt64) {
        self.value = value
    }

    /// The initial epoch before any updates.
    public static let zero = Epoch(value: 0)

    /// Returns the next epoch (current + 1).
    public func advanced() -> Epoch {
        Epoch(value: value + 1)
    }

    public static func < (lhs: Epoch, rhs: Epoch) -> Bool {
        lhs.value < rhs.value
    }
}

extension Epoch: CustomStringConvertible {
    public var description: String {
        "epoch-\(value)"
    }
}
