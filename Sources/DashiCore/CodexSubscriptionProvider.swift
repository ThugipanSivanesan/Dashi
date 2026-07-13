import Foundation

/// Reads the Codex (ChatGPT) subscription's rolling limits from the same OAuth usage endpoint the
/// Codex CLI calls internally (`chatgpt.com/backend-api/wham/usage`). Personal-use and read-only:
/// it reuses the Codex CLI's locally-stored OAuth token and never writes back to `auth.json`.
///
/// Codex reports its rolling windows as `primary_window` / `secondary_window`, but — unlike Claude's
/// named `five_hour` / `seven_day` — those positions are not a fixed 5-hour/weekly assignment: a plan
/// may surface only one window (e.g. Plus returns the weekly window as `primary_window` with
/// `secondary_window` null). Each window's true horizon is carried by `limit_window_seconds`, which we
/// route on to fill the same ``SubscriptionLimits`` shape as the Claude gauge.
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
    /// `used_percent`, an epoch-seconds `reset_at`, and a `limit_window_seconds` horizon — into
    /// ``SubscriptionLimits``. Windows are placed by their horizon, not their position: any window
    /// shorter than a day fills the 5-hour slot, a day or longer fills the weekly slot. Missing or
    /// unclassifiable windows are nil.
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
                let limitWindowSeconds: Double?
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
        // 5-hour ≈ 18000s, weekly ≈ 604800s; one day cleanly separates the two horizons. A window
        // without `limit_window_seconds` can't be placed, so it's dropped. First match wins per
        // slot, so a duplicate horizon can't clobber an already-filled slot.
        let oneDay: Double = 24 * 3600
        var fiveHourWindow: Response.Window?
        var weeklyWindow: Response.Window?
        for window in [decoded.rateLimit?.primaryWindow, decoded.rateLimit?.secondaryWindow] {
            guard let window, let seconds = window.limitWindowSeconds else { continue }
            if seconds < oneDay {
                fiveHourWindow = fiveHourWindow ?? window
            } else {
                weeklyWindow = weeklyWindow ?? window
            }
        }
        func limit(_ window: Response.Window?) -> RollingLimit? {
            guard let window else { return nil }
            return RollingLimit(
                utilization: window.usedPercent ?? 0,
                resetsAt: window.resetAt.map { Date(timeIntervalSince1970: $0) }
            )
        }
        return SubscriptionLimits(
            fiveHour: limit(fiveHourWindow),
            sevenDay: limit(weeklyWindow),
            fetchedAt: fetchedAt
        )
    }
}
