import Foundation
#if canImport(Security)
// The Keychain, on macOS.
import Security
#endif
#if os(Windows)
import WinSDK
#endif

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
    #if canImport(Security)
    /// The Keychain's status code; never the key.
    case keychain(OSStatus)
    #endif
    #if os(Windows)
    /// A Windows error code, such as `ERROR_ACCESS_DENIED`; never the key.
    case system(Int)
    #endif
}

/// The store this system uses.
public enum KeyStores {
    public static func system() -> KeyStore {
        #if os(Windows)
        return CredentialManagerKeyStore()
        #elseif canImport(Security)
        return KeychainKeyStore()
        #else
        return MemoryKeyStore()  // A platform with neither: a key lasts for one run.
        #endif
    }
}

#if canImport(Security)
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
#endif

#if os(Windows)
/// Keys as generic credentials in Windows Credential Manager, under `AgentHive/usage/<service>`.
///
/// `CRED_PERSIST_LOCAL_MACHINE` makes Windows encrypt them for this machine and this user only, so they never
/// travel with a roaming profile: the same promise the login Keychain keeps on the Mac, in the place Windows
/// users look for credentials (Control Panel > Credential Manager > Windows Credentials).
public struct CredentialManagerKeyStore: KeyStore {
    public static let defaultPrefix = "AgentHive/usage"
    /// What comes before the service id in the target name. Tests pass a throwaway prefix.
    public let prefix: String

    public init(prefix: String = CredentialManagerKeyStore.defaultPrefix) {
        self.prefix = prefix
    }

    func target(for account: String) -> String { "\(prefix)/\(account)" }

    /// The credential's blob as text, or nil. Never logged, never put in an error.
    public func key(for account: String) -> String? {
        guard let data = read(target(for: account)), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func hasKey(for account: String) -> Bool { read(target(for: account)) != nil }

    public func save(_ key: String, for account: String) throws {
        let key = Text.strip(key)
        guard !key.isEmpty else { throw KeyStoreError.empty }
        let bytes = Array(key.utf8)
        let name = target(for: account)
        var written: Bool = false
        var code: DWORD = 0

        bytes.withUnsafeBufferPointer { blob in
            name.withCString(encodedAs: UTF16.self) { target in
                var credential = CREDENTIALW()
                credential.Type = DWORD(CRED_TYPE_GENERIC)
                credential.TargetName = UnsafeMutablePointer(mutating: target)
                credential.CredentialBlobSize = DWORD(blob.count)
                credential.CredentialBlob = UnsafeMutablePointer(mutating: blob.baseAddress)
                credential.Persist = DWORD(CRED_PERSIST_LOCAL_MACHINE)
                written = CredWriteW(&credential, 0)
                code = written ? 0 : GetLastError()
            }
        }
        guard written else { throw KeyStoreError.system(Int(code)) }
    }

    public func remove(service account: String) throws {
        let name = target(for: account)
        var removed = false
        var code: DWORD = 0
        name.withCString(encodedAs: UTF16.self) { target in
            removed = CredDeleteW(target, DWORD(CRED_TYPE_GENERIC), 0)
            code = removed ? 0 : GetLastError()
        }
        // Removing a key that is not there is what the caller wanted.
        guard removed || code == DWORD(ERROR_NOT_FOUND) else { throw KeyStoreError.system(Int(code)) }
    }

    private func read(_ name: String) -> Data? {
        var credential: PCREDENTIALW?
        var found = false
        name.withCString(encodedAs: UTF16.self) { target in
            found = CredReadW(target, DWORD(CRED_TYPE_GENERIC), 0, &credential)
        }
        guard found, let stored = credential else { return nil }
        defer { CredFree(stored) }
        let size = Int(stored.pointee.CredentialBlobSize)
        guard size > 0, let blob = stored.pointee.CredentialBlob else { return nil }
        return Data(bytes: blob, count: size)
    }
}
#endif

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
