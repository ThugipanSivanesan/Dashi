import Foundation

/// The OAuth credentials the OpenAI Codex CLI stores locally in `auth.json`. The tokens are wrapped
/// in ``Secret`` so they never print. `lastRefresh` mirrors the CLI's own refresh bookkeeping and
/// lets a future refresh path decide when a token is stale (the CLI rotates at 8 days).
public struct CodexOAuthToken: Sendable, Equatable {
    public let accessToken: Secret
    /// ChatGPT account id, sent as the `ChatGPT-Account-Id` header. `nil` on API-key-only setups.
    public let accountId: String?
    /// Rotating refresh token. Parsed but unused today — Dashi is read-only and never rewrites
    /// `auth.json` (see ``CodexSubscriptionProvider``). Kept so a deliberate refresh path can be
    /// added later without reshaping the reader.
    public let refreshToken: Secret?
    /// When the CLI last refreshed the tokens, if recorded.
    public let lastRefresh: Date?

    public init(
        accessToken: Secret,
        accountId: String? = nil,
        refreshToken: Secret? = nil,
        lastRefresh: Date? = nil
    ) {
        self.accessToken = accessToken
        self.accountId = accountId
        self.refreshToken = refreshToken
        self.lastRefresh = lastRefresh
    }

    /// The CLI refreshes when `last_refresh` is older than 8 days; exposed for a future refresh path.
    public func isStale(now: Date = Date()) -> Bool {
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) > 8 * 24 * 3600
    }
}

/// Reads the Codex CLI OAuth token. Abstracted so tests use ``StubCodexCredentialsReader`` and never
/// touch the real filesystem — mirrors the ``ClaudeCredentialsReading`` split.
public protocol CodexCredentialsReading: Sendable {
    /// Returns the current token, or `nil` if the user isn't logged in to the Codex CLI.
    func currentToken() throws -> CodexOAuthToken?
}

/// Production reader: the `auth.json` the Codex CLI writes under `~/.codex` (or `$CODEX_HOME` when
/// set). Unlike the Claude reader there's no Keychain item — Codex keeps credentials in a plain file.
///
/// Credential location/format matches the OpenAI Codex CLI (`~/.codex/auth.json`).
public struct CodexCredentialsReader: CodexCredentialsReading {
    private let fileURL: URL

    public init(fileURL: URL = CodexCredentialsReader.defaultAuthFileURL()) {
        self.fileURL = fileURL
    }

    /// `$CODEX_HOME/auth.json` when `CODEX_HOME` is set and non-empty, else `~/.codex/auth.json`.
    public static func defaultAuthFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let base: URL
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            base = URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
        } else {
            base = home.appendingPathComponent(".codex")
        }
        return base.appendingPathComponent("auth.json")
    }

    public func currentToken() throws -> CodexOAuthToken? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try Self.parse(data)
    }

    /// Parses `{ "tokens": { "access_token", "refresh_token", "account_id" }, "last_refresh": ... }`.
    /// Returns `nil` when there's no usable access token (e.g. an API-key-only file), which the
    /// caller maps to "not signed in" — the `wham/usage` endpoint needs a Bearer access token.
    static func parse(_ data: Data) throws -> CodexOAuthToken? {
        struct Root: Decodable {
            let tokens: Tokens?
            let lastRefresh: String?
            struct Tokens: Decodable {
                let accessToken: String?
                let refreshToken: String?
                let accountId: String?
            }
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let root = try decoder.decode(Root.self, from: data)
        guard let access = root.tokens?.accessToken, !access.isEmpty else { return nil }
        return CodexOAuthToken(
            accessToken: Secret(access),
            accountId: root.tokens?.accountId,
            refreshToken: root.tokens?.refreshToken.map(Secret.init),
            lastRefresh: root.lastRefresh.flatMap(Self.parseDate)
        )
    }

    /// `last_refresh` is an ISO-8601 timestamp; tolerate the fractional-seconds variant too.
    static func parseDate(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

/// Test/preview reader backed by a closure so it can return a token, `nil`, or throw.
public struct StubCodexCredentialsReader: CodexCredentialsReading {
    private let provide: @Sendable () throws -> CodexOAuthToken?

    public init(_ provide: @escaping @Sendable () throws -> CodexOAuthToken?) {
        self.provide = provide
    }

    public init(token: CodexOAuthToken?) {
        self.provide = { token }
    }

    public func currentToken() throws -> CodexOAuthToken? {
        try provide()
    }
}
