import Foundation
import Security

public enum OpenRouterSecretError: Error, LocalizedError, Equatable, Sendable {
    case invalidKey
    case missingKey
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidKey: "Enter a valid API key."
        case .missingKey: "Add an OpenRouter API key in Settings."
        case .unavailable: "The macOS Keychain is unavailable. Try again after unlocking this Mac."
        }
    }
}

public protocol OpenRouterSecretReading: Sendable {
    func readKey() throws -> String
}

/// The only persisted OpenRouter credential is this generic-password Keychain item.
public struct OpenRouterSecretVault: OpenRouterSecretReading, Sendable {
    private let service: String
    private let account = "api-key"

    public init(service: String = "com.cliphelm.openrouter") {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func hasKey() throws -> Bool {
        var request = query
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(request as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw OpenRouterSecretError.unavailable
        }
    }

    public func readKey() throws -> String {
        var request = query
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { throw OpenRouterSecretError.missingKey }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw OpenRouterSecretError.unavailable
        }
        return key
    }

    public func save(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 512,
              key.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }) else {
            throw OpenRouterSecretError.invalidKey
        }
        let data = Data(key.utf8)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrLabel as String] = "ClipHelm OpenRouter API Key"

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: data]
            guard SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess else {
                throw OpenRouterSecretError.unavailable
            }
        } else if status != errSecSuccess {
            throw OpenRouterSecretError.unavailable
        }
    }

    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenRouterSecretError.unavailable
        }
    }
}
