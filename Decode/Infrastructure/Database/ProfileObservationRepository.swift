import Foundation

/// Lightweight repository encapsulating profile observation persistence.
///
/// Responsibilities are limited to CRUD operations — no derivation logic,
/// no business rules, no caching. Delegates to ``DatabaseServiceProtocol``
/// for actual storage, keeping the repository testable via protocol injection.
struct ProfileObservationRepository: Sendable {

    private let database: any DatabaseServiceProtocol

    init(database: any DatabaseServiceProtocol) {
        self.database = database
    }

    /// Persist a new observation.
    func insert(_ observation: ProfileObservation) async throws {
        try await database.createProfileObservation(observation)
    }

    /// Fetch all observations, ordered by timestamp ascending.
    func fetchAll() async throws -> [ProfileObservation] {
        try await database.fetchAllProfileObservations()
    }

    /// Fetch observations recorded on or after the given date, ordered by timestamp ascending.
    func fetchSince(_ date: Date) async throws -> [ProfileObservation] {
        try await database.fetchProfileObservations(since: date)
    }

    /// Return the total number of stored observations.
    func count() async throws -> Int {
        try await database.countProfileObservations()
    }

    /// Delete all stored observations. Used for developer tooling / reset.
    func deleteAll() async throws {
        try await database.deleteAllProfileObservations()
    }
}
