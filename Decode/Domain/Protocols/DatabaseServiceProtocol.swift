import Foundation

/// Defines the contract for all persistent storage operations.
///
/// The Domain and Application layers depend on this protocol, never on the
/// concrete GRDB implementation. This allows swapping the storage backend
/// and injecting in-memory fakes for testing.
///
/// All methods are async to support actor-isolated database access.
protocol DatabaseServiceProtocol: Sendable {

    // MARK: - Sessions

    func createSession(_ session: Session) async throws
    func fetchSession(id: UUID) async throws -> Session?
    func fetchAllSessions() async throws -> [Session]
    func updateSession(_ session: Session) async throws
    func deleteSession(id: UUID) async throws

    // MARK: - Entities

    func createEntity(_ entity: CodeEntity) async throws
    func fetchEntities(sessionId: UUID) async throws -> [CodeEntity]
    func fetchEntity(id: UUID) async throws -> CodeEntity?
    func fetchEntity(stableId: String, sessionId: UUID) async throws -> CodeEntity?
    func updateEntity(_ entity: CodeEntity) async throws
    func deleteEntity(id: UUID) async throws
    func deleteEntities(ids: [UUID]) async throws

    // MARK: - Entity Dependencies

    func createDependency(_ dependency: EntityDependency) async throws
    func fetchDependencies(parentId: UUID) async throws -> [EntityDependency]
    func fetchDependents(childId: UUID) async throws -> [EntityDependency]
    func deleteDependencies(parentId: UUID) async throws
    func replaceDependencies(parentId: UUID, newDependencies: [EntityDependency]) async throws

    // MARK: - Messages

    func createMessage(_ message: ChatMessage) async throws
    func fetchMessages(sessionId: UUID) async throws -> [ChatMessage]
    func deleteMessages(sessionId: UUID) async throws
}
