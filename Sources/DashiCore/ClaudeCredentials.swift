import Foundation
import Security

/// The OAuth access token Claude Code stores locally. The token itself is wrapped in ``Secret`` so
/// it never prints; `expiresAt` lets callers detect a stale token before using it.
public struct ClaudeOAuthToken: Sendable, Equatable {
    public let accessToken: Secret
    public let expiresAt: Date?

    public init(accessToken: Secret, expiresAt: Date?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

public enum CredentialsError: Error, Equatable {
    case keychain(OSStatus)
}

/// Reads the Claude Code OAuth token. Abstracted so tests use ``StubCredentialsReader`` and never
/// touch the real Keychain — mirrors the ``SecretStore`` / ``InMemorySecretStore`` split.
public protocol ClaudeCredentialsReading: Sendable {
    /// Returns the current token, or `nil` if the user isn't signed in to Claude Code.
    func currentToken() throws -> ClaudeOAuthToken?
}

/// Production reader: the macOS Keychain generic-password item Claude Code writes (service
/// "Claude Code-credentials"), falling back to `~/.claude/.credentials.json` on setups that use it.
///
/// Credential locations/format informed by griffinmartin/opencode-claude-auth (MIT).
/// https://github.com/griffinmartin/opencode-claude-auth
public struct ClaudeCredentialsReader: ClaudeCredentialsReading {
    private let keychainService: String
    private let fileURL: URL

    public init(
        keychainService: String = "Claude Code-credentials",
        fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    ) {
        self.keychainService = keychainService
        self.fileURL = fileURL
    }

    public func currentToken() throws -> ClaudeOAuthToken? {
        guard let data = try keychainData() ?? fileData() else { return nil }
        return try Self.parse(data)
    }

    private func keychainData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialsError.keychain(status) }
        return item as? Data
    }

    private func fileData() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    /// Parses the `{ "claudeAiOauth": { "accessToken", "expiresAt" } }` payload. `expiresAt` is epoch
    /// milliseconds in Claude Code's format; we normalise it to seconds.
    static func parse(_ data: Data) throws -> ClaudeOAuthToken? {
        struct Root: Decodable {
            let claudeAiOauth: OAuth?
            struct OAuth: Decodable {
                let accessToken: String
                let expiresAt: Double?
            }
        }
        let root = try JSONDecoder().decode(Root.self, from: data)
        guard let oauth = root.claudeAiOauth, !oauth.accessToken.isEmpty else { return nil }
        let expiry = oauth.expiresAt.map { raw -> Date in
            let seconds = raw > 1_000_000_000_000 ? raw / 1000 : raw
            return Date(timeIntervalSince1970: seconds)
        }
        return ClaudeOAuthToken(accessToken: Secret(oauth.accessToken), expiresAt: expiry)
    }
}

/// Test/preview reader backed by a closure so it can return a token, `nil`, or throw.
public struct StubCredentialsReader: ClaudeCredentialsReading {
    private let provide: @Sendable () throws -> ClaudeOAuthToken?

    public init(_ provide: @escaping @Sendable () throws -> ClaudeOAuthToken?) {
        self.provide = provide
    }

    public init(token: ClaudeOAuthToken?) {
        self.provide = { token }
    }

    public func currentToken() throws -> ClaudeOAuthToken? {
        try provide()
    }
}
