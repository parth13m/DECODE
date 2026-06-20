import Foundation
import Security

/// Provides secure storage for sensitive values (API keys) using the macOS Keychain.
///
/// In a sandboxed app, Keychain items are automatically scoped to the application.
/// Items are identified by a service name + account name pair.
struct KeychainService: Sendable {

    private let serviceName: String

    init(serviceName: String = "com.decode.app") {
        self.serviceName = serviceName
    }

    /// Store a string value in the Keychain.
    ///
    /// If a value already exists for the given account, it is updated.
    func store(_ value: String, forAccount account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]

        // Try to delete any existing item first, then add.
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
    }

    /// Retrieve a string value from the Keychain.
    ///
    /// Returns `nil` if no value exists for the given account.
    func retrieve(forAccount account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.retrieveFailed(status)
        }

        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.decodingFailed
        }

        return string
    }

    /// Delete a value from the Keychain.
    func delete(forAccount account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

/// Errors from Keychain operations.
enum KeychainError: Error, LocalizedError {
    case encodingFailed
    case decodingFailed
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            "Failed to encode the value for Keychain storage."
        case .decodingFailed:
            "Failed to decode the value from Keychain."
        case .storeFailed(let status):
            "Keychain store failed with status \(status)."
        case .retrieveFailed(let status):
            "Keychain retrieval failed with status \(status)."
        case .deleteFailed(let status):
            "Keychain deletion failed with status \(status)."
        }
    }
}
