import Foundation

/// Domain-level business logic for session lifecycle management.
///
/// Handles session creation rules, validation, and state transitions.
/// Operates on domain models via DatabaseServiceProtocol -- never touches
/// GRDB or any infrastructure directly.
///
/// Implemented in Phase 4.
final class SessionService: Sendable {

    init() {}
}
