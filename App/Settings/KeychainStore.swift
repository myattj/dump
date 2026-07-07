import Foundation
import Security

/// Thin wrapper around the macOS Keychain for storing API keys. Generic
/// password class, scoped to the Dump bundle id.
public final class KeychainStore: @unchecked Sendable {
    public static let shared = KeychainStore()

    public enum Key: String, CaseIterable, Sendable {
        case anthropicAPIKey = "anthropic.api_key"
        case customLLMAPIKey = "custom_llm.api_key"
        case bedrockAccessKeyID = "bedrock.access_key_id"
        case bedrockSecretAccessKey = "bedrock.secret_access_key"
        case bedrockSessionToken = "bedrock.session_token"
    }

    private let service: String

    public init(service: String = "com.joshmyatt.dump") {
        self.service = service
    }

    public func set(_ value: String?, for key: Key) throws {
        if let value, !value.isEmpty {
            try set(data: Data(value.utf8), account: key.rawValue)
        } else {
            try delete(account: key.rawValue)
        }
    }

    public func string(for key: Key) -> String? {
        guard let data = try? get(account: key.rawValue) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(_ key: Key) throws {
        try delete(account: key.rawValue)
    }

    private func set(data: Data, account: String) throws {
        try delete(account: account)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    private func get(account: String) throws -> Data {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(status: status)
        }
        return data
    }

    private func delete(account: String) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(q as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError(status: status)
        }
    }

    public struct KeychainError: Error, Equatable {
        public let status: OSStatus
    }
}
