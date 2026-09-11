import Foundation

/// Performs an HTTP request. Injectable so tests exercise the request/response path without network.
public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// Reads the Claude subscription's rolling limits from the OAuth usage endpoint that Claude Code's
/// `/usage` command uses. Personal-use, read-only: reuses the locally-stored Claude Code OAuth token.
public struct ClaudeSubscriptionProvider: LimitProvider {
    private let credentials: any ClaudeCredentialsReading
    private let transport: HTTPTransport
    private let endpoint: URL
    private let now: @Sendable () -> Date

    public init(
        credentials: any ClaudeCredentialsReading = ClaudeCredentialsReader(),
        transport: @escaping HTTPTransport = ClaudeSubscriptionProvider.urlSessionTransport,
        endpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentials = credentials
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

    public func currentLimits() async throws -> SubscriptionLimits {
        try Self.validateEndpoint(endpoint)

        let token: ClaudeOAuthToken?
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
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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
        let windows = (decoded.limits ?? []).compactMap(limitWindow)
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
    let limits: [Entry]?

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
