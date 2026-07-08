import Foundation

/// Reads the Codex (ChatGPT) subscription's rolling limits from the same OAuth usage endpoint the
/// Codex CLI calls internally (`chatgpt.com/backend-api/wham/usage`). Personal-use and read-only:
/// it reuses the Codex CLI's locally-stored OAuth token and never writes back to `auth.json`.
///
/// Codex's `primary_window` (5-hour) and `secondary_window` (weekly) map onto the same
/// ``SubscriptionLimits`` shape as the Claude gauge, so both providers render identically.
///
/// Refresh note: Codex uses rotating refresh tokens, so refreshing would mean rewriting the CLI's
/// `auth.json` — a mutation of another tool's credentials that can invalidate the CLI's own login if
/// done wrong. Dashi deliberately does not refresh: on a rejected token it surfaces
/// ``LimitError/needsReauth`` (run `codex` to re-authenticate), matching the Claude provider.
public struct CodexSubscriptionProvider: LimitProvider {
    private let credentials: any CodexCredentialsReading
    private let transport: HTTPTransport
    private let endpoint: URL
    private let now: @Sendable () -> Date

    public init(
        credentials: any CodexCredentialsReading = CodexCredentialsReader(),
        transport: @escaping HTTPTransport = ClaudeSubscriptionProvider.urlSessionTransport,
        endpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentials = credentials
        self.transport = transport
        self.endpoint = endpoint
        self.now = now
    }

    /// The only host this provider may attach the OAuth token to.
    static let allowedHost = "chatgpt.com"

    /// Refuses to reveal the bearer token to anything but HTTPS on ``allowedHost``. The endpoint is
    /// injectable for tests, so this is defense-in-depth against a misconfigured/injected URL
    /// exfiltrating the credential to an unintended or plaintext destination.
    static func validateEndpoint(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
            url.host?.lowercased() == allowedHost
        else {
            throw LimitError.requestFailed("refusing to send credentials to an unexpected endpoint")
        }
    }

    public func currentLimits() async throws -> SubscriptionLimits {
        try Self.validateEndpoint(endpoint)

        let token: CodexOAuthToken?
        do {
            token = try credentials.currentToken()
        } catch {
            throw LimitError.requestFailed("credentials: \(error)")
        }
        guard let token else { throw LimitError.notSignedIn }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(
            "Bearer \(token.accessToken.reveal())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Dashi", forHTTPHeaderField: "User-Agent")
        if let accountId = token.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as LimitError {
            throw error
        } catch {
            throw LimitError.requestFailed(error.localizedDescription)
        }

        switch response.statusCode {
        case 200:
            return try Self.decodeUsage(data, fetchedAt: now())
        case 401, 403:
            throw LimitError.needsReauth
        case 429:
            throw LimitError.rateLimited(retryAfter: parseRetryAfter(response, now: now()))
        default:
            throw LimitError.requestFailed("HTTP \(response.statusCode)")
        }
    }

    /// Decodes the `wham/usage` payload — `rate_limit.primary_window` / `secondary_window`, each with
    /// `used_percent` and an epoch-seconds `reset_at` — into ``SubscriptionLimits`` (primary → 5-hour,
    /// secondary → weekly).
    static func decodeUsage(_ data: Data, fetchedAt: Date) throws -> SubscriptionLimits {
        struct Response: Decodable {
            let rateLimit: RateLimit?
            struct RateLimit: Decodable {
                let primaryWindow: Window?
                let secondaryWindow: Window?
            }
            struct Window: Decodable {
                let usedPercent: Double?
                let resetAt: Double?
            }
        }
        let decoded: Response
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoded = try decoder.decode(Response.self, from: data)
        } catch {
            throw LimitError.requestFailed("decode: \(error.localizedDescription)")
        }
        func limit(_ window: Response.Window?) -> RollingLimit {
            RollingLimit(
                utilization: window?.usedPercent ?? 0,
                resetsAt: window?.resetAt.map { Date(timeIntervalSince1970: $0) }
            )
        }
        return SubscriptionLimits(
            fiveHour: limit(decoded.rateLimit?.primaryWindow),
            sevenDay: limit(decoded.rateLimit?.secondaryWindow),
            fetchedAt: fetchedAt
        )
    }
}
