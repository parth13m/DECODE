import Foundation
import Testing
@testable import Decode

/// Tests for KeychainService.
///
/// Uses a unique service name per test to avoid cross-test contamination.
struct KeychainServiceTests {

    private func makeKeychain() -> KeychainService {
        KeychainService(serviceName: "com.decode.test.\(UUID().uuidString)")
    }

    @Test func storeAndRetrieve() throws {
        let keychain = makeKeychain()
        let account = "test-api-key"

        try keychain.store("sk-test-12345", forAccount: account)

        let retrieved = try keychain.retrieve(forAccount: account)
        #expect(retrieved == "sk-test-12345")

        // Clean up
        try keychain.delete(forAccount: account)
    }

    @Test func retrieveNonexistent() throws {
        let keychain = makeKeychain()

        let retrieved = try keychain.retrieve(forAccount: "nonexistent")
        #expect(retrieved == nil)
    }

    @Test func updateExistingKey() throws {
        let keychain = makeKeychain()
        let account = "test-update"

        try keychain.store("original-key", forAccount: account)
        try keychain.store("updated-key", forAccount: account)

        let retrieved = try keychain.retrieve(forAccount: account)
        #expect(retrieved == "updated-key")

        try keychain.delete(forAccount: account)
    }

    @Test func deleteKey() throws {
        let keychain = makeKeychain()
        let account = "test-delete"

        try keychain.store("to-be-deleted", forAccount: account)
        try keychain.delete(forAccount: account)

        let retrieved = try keychain.retrieve(forAccount: account)
        #expect(retrieved == nil)
    }

    @Test func deleteNonexistentDoesNotThrow() throws {
        let keychain = makeKeychain()
        try keychain.delete(forAccount: "never-existed")
    }
}
