import Foundation
import Security

/// Where usage-service API keys are kept. Keys are only read here, sent only to their own service, and never
/// logged or included in any page JSON.
public protocol KeyStore: Sendable {
    func key(for service: String) -> String?
    /// Whether a key is saved, without reading it (reading a Keychain item's data can ask the user).
    func hasKey(for service: String) -> Bool
    func save(_ key: String, for service: String) throws
    func remove(service: String) throws
}

extension KeyStore {
    public func hasKey(for service: String) -> Bool { key(for: service) != nil }
}

public enum KeyStoreError: Error, Equatable, Sendable {
    case empty
    /// The Keychain's status code; never the key.
    case keychain(OSStatus)
}

/// Keys as generic passwords in the login Keychain: service `io.github.agenthive.AgentHive.usage`,
/// account = the usage service's id (`deepseek`, `openrouter`, `openai`, `anthropic`).
public struct KeychainKeyStore: KeyStore {
    public static let defaultService = "io.github.agenthive.AgentHive.usage"
    public let service: String

    public init(service: String = KeychainKeyStore.defaultService) {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func key(for account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    public func hasKey(for account: String) -> Bool {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    public func save(_ key: String, for account: String) throws {
        let key = Text.strip(key)
        guard !key.isEmpty else { throw KeyStoreError.empty }
        let data = Data(key.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeyStoreError.keychain(update) }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Agent Hive: \(account) API key"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
    }

    public func remove(service account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyStoreError.keychain(status) }
    }
}

/// Keys in memory, for tests and previews.
public final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String]

    public init(_ keys: [String: String] = [:]) {
        self.keys = keys
    }

    public func key(for service: String) -> String? { lock.withLock { keys[service] } }

    public func save(_ key: String, for service: String) throws {
        let key = Text.strip(key)
        guard !key.isEmpty else { throw KeyStoreError.empty }
        lock.withLock { keys[service] = key }
    }

    public func remove(service: String) throws { _ = lock.withLock { keys.removeValue(forKey: service) } }
}
