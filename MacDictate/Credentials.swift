import Foundation
import Security

protocol SecureCredentialStore: Sendable {
    func load() throws -> String?
    func save(_ credential: String) throws
    func delete() throws
}

enum CredentialConstants {
    static let service = "com.macdictate.app.openai"
    static let account = "OpenAI API Key"
}

enum CredentialStoreError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
            return "Keychain error \(status): \(message)"
        case .invalidData:
            return "The saved API key could not be read."
        }
    }
}

final class KeychainCredentialStore: SecureCredentialStore {
    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.unexpectedStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidData
        }
        return value
    }

    func save(_ credential: String) throws {
        let data = Data(credential.utf8)
        var insert = baseQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let attributes = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw CredentialStoreError.unexpectedStatus(updateStatus)
            }
        } else if status != errSecSuccess {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CredentialConstants.service,
            kSecAttrAccount as String: CredentialConstants.account
        ]
    }
}

