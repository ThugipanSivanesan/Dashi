import Foundation

/// Performs an HTTP request. Injectable so tests exercise the request/response path without network.
public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// Reads the Claude subscription's rolling limits from the OAuth usage endpoint that Claude Code's
/// `/usage` command uses. Personal-use, read-only: reuses the locally-stored Claude Code OAuth token.
public struct ClaudeSubscriptionProvider: LimitProvider {
    private let cache: ClaudeTokenCache
    private let transport: HTTPTransport
    private let endpoint: URL
    private let now: @Sendable () -> Date

    public init(
        credentials: any ClaudeCredentialsReading = ClaudeCredentialsReader(),
        transport: @escaping HTTPTransport = ClaudeSubscriptionProvider.urlSessionTransport,
        endpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.cache = ClaudeTokenCache(reader: credentials, now: now)
        self.transport = transport
        self.endpoint = endpoint
        self.now = now
    }

    /// The only host this provider may attach the OAuth token to.
    static let allowedHost = "api.anthropic.com"

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

    /// The statuses that mean the endpoint refused the token we sent.
    static let rejectionStatuses: Set<Int> = [401, 403]

    public func currentLimits() async throws -> SubscriptionLimits {
        try Self.validateEndpoint(endpoint)

        guard let sent = try readToken() else { throw LimitError.notSignedIn }
        let (data, response) = try await send(sent.token)
        guard Self.rejectionStatuses.contains(response.statusCode) else {
            return try limits(from: data, response: response)
        }

        cache.invalidate()
        guard sent.isCached else { throw LimitError.needsReauth }
        guard let reread = try readToken() else { throw LimitError.notSignedIn }
        guard reread.token != sent.token else { throw LimitError.needsReauth }

        let (retryData, retryResponse) = try await send(reread.token)
        guard !Self.rejectionStatuses.contains(retryResponse.statusCode) else {
            cache.invalidate()
            throw LimitError.needsReauth
        }
        return try limits(from: retryData, response: retryResponse)
    }

    /// Reads the token through the cache, reporting a reader failure as a failed request.
    private func readToken() throws -> (token: ClaudeOAuthToken, isCached: Bool)? {
        do {
            return try cache.token()
        } catch {
            throw LimitError.requestFailed("credentials: \(error)")
        }
    }

    /// Requests the usage endpoint with the token as the bearer credential.
    private func send(_ token: ClaudeOAuthToken) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(
            "Bearer \(token.accessToken.reveal())", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            return try await transport(request)
        } catch let error as LimitError {
            throw error
        } catch {
            throw LimitError.requestFailed(error.localizedDescription)
        }
    }

    /// Turns a response the endpoint did not reject into limits, throwing for any status but 200.
    private func limits(
        from data: Data, response: HTTPURLResponse
    ) throws -> SubscriptionLimits {
        switch response.statusCode {
        case 200:
            return try Self.decodeUsage(data, fetchedAt: now())
        case 429:
            throw LimitError.rateLimited(retryAfter: parseRetryAfter(response, now: now()))
        default:
            throw LimitError.requestFailed("HTTP \(response.statusCode)")
        }
    }

    /// Default transport using `URLSession`.
    public static let urlSessionTransport: HTTPTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LimitError.requestFailed("non-HTTP response")
        }
        return (data, http)
    }

    /// Decodes the payload's `limits` array into ``SubscriptionLimits``, falling back to the legacy
    /// `{ "five_hour": {...}, "seven_day": {...} }` keys when it reports no window.
    static func decodeUsage(_ data: Data, fetchedAt: Date) throws -> SubscriptionLimits {
        let decoded: UsageResponse
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoded = try decoder.decode(UsageResponse.self, from: data)
        } catch {
            throw LimitError.requestFailed("decode: \(error.localizedDescription)")
        }
        let entries = (decoded.limits?.value ?? []).compactMap(\.value)
        let windows = entries.compactMap(limitWindow)
        if !windows.isEmpty {
            return SubscriptionLimits(windows: windows, fetchedAt: fetchedAt)
        }
        return SubscriptionLimits(
            fiveHour: rollingLimit(decoded.fiveHour),
            sevenDay: rollingLimit(decoded.sevenDay),
            fetchedAt: fetchedAt
        )
    }

    /// Parses the endpoint's timestamps, which use microsecond precision and a `+00:00` offset
    /// (e.g. "2026-06-29T11:00:00.968660+00:00") — beyond what `ISO8601DateFormatter` reliably
    /// handles — so we fall back to stripping the fractional seconds before retrying.
    static func parseDate(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }

        guard let dot = string.firstIndex(of: ".") else { return nil }
        var end = string.index(after: dot)
        while end < string.endIndex, string[end].isNumber {
            end = string.index(after: end)
        }
        return plain.date(from: string.replacingCharacters(in: dot..<end, with: ""))
    }
}

/// The usage endpoint's payload: the `limits` array of reported windows, and the legacy named
/// windows that predate it.
private struct UsageResponse: Decodable {
    let fiveHour: Window?
    let sevenDay: Window?
    let limits: Lenient<[Lenient<Entry>]>?

    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?
    }

    struct Entry: Decodable {
        let kind: String?
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?
    }

    struct Scope: Decodable {
        let model: Model?

        struct Model: Decodable {
            let displayName: String?
        }
    }
}

/// Decodes `T` when the payload matches it, and yields a `nil` ``value`` instead of throwing when
/// it does not.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// Converts a legacy named window into a ``RollingLimit``, or `nil` when the key is absent.
private func rollingLimit(_ window: UsageResponse.Window?) -> RollingLimit? {
    guard let window else { return nil }
    return RollingLimit(
        utilization: window.utilization ?? 0,
        resetsAt: window.resetsAt.flatMap(ClaudeSubscriptionProvider.parseDate)
    )
}

/// Maps one `limits` entry onto a titled window, dropping any entry whose kind is unrecognised and
/// any scoped entry that names no model.
private func limitWindow(_ entry: UsageResponse.Entry) -> LimitWindow? {
    let limit = RollingLimit(
        utilization: entry.percent ?? 0,
        resetsAt: entry.resetsAt.flatMap(ClaudeSubscriptionProvider.parseDate)
    )
    switch entry.kind {
    case "session":
        return LimitWindow(title: "5-hour", kind: .session, limit: limit)
    case "weekly_all":
        return LimitWindow(title: "Weekly", kind: .weekly, limit: limit)
    case "weekly_scoped":
        guard let title = entry.scope?.model?.displayName else { return nil }
        return LimitWindow(title: title, kind: .weeklyScoped, limit: limit)
    default:
        return nil
    }
}
