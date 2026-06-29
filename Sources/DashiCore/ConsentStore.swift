import Foundation

/// Persists whether the user has acknowledged the experimental / ToS risk of the Claude
/// subscription gauge. Non-secret, so it lives in `UserDefaults` (never the Keychain).
public protocol ConsentStore: Sendable {
    func hasConsented() -> Bool
    func setConsented(_ value: Bool)
}

public struct UserDefaultsConsentStore: ConsentStore {
    private let key: String

    public init(key: String = "dashi.claudeGaugeConsent") {
        self.key = key
    }

    public func hasConsented() -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    public func setConsented(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

/// In-memory consent store for tests and previews.
public final class InMemoryConsentStore: ConsentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    public init(_ initial: Bool = false) {
        value = initial
    }

    public func hasConsented() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func setConsented(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}
