import Foundation
import Security

/// Errors surfaced by a ``SecretStore`` implementation.
public enum SecretStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

/// Abstraction over secret persistence so the production Keychain path can be swapped for an
/// in-memory store in tests (which never touch the real Keychain).
public protocol SecretStore: Sendable {
    func set(_ secret: Secret, for key: String) throws
    func get(_ key: String) throws -> Secret?
    func delete(_ key: String) throws
}

/// macOS Keychain-backed secret store. This is the only place provider API keys exist in
/// plaintext, and there they are encrypted at rest by the OS — never written to a file in the repo.
public struct KeychainStore: SecretStore {
    private let service: String

    public init(service: String = "com.dashi") {
        self.service = service
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func set(_ secret: Secret, for key: String) throws {
        let data = Data(secret.reveal().utf8)
        let query = baseQuery(key)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let attrs = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SecretStoreError.unexpectedStatus(updateStatus)
            }
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretStoreError.unexpectedStatus(addStatus)
            }
        default:
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    public func get(_ key: String) throws -> Secret? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return Secret(str)
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }
}

/// In-memory secret store for tests and offline development. Never persists to disk.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init(_ initial: [String: String] = [:]) {
        storage = initial
    }

    public func set(_ secret: Secret, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = secret.reveal()
    }

    public func get(_ key: String) throws -> Secret? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key].map(Secret.init)
    }

    public func delete(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = nil
    }
}
