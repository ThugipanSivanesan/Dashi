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

    public func currentLimits() async throws -> SubscriptionLimits {
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

    /// Decodes the `{ "five_hour": {...}, "seven_day": {...} }` payload into ``SubscriptionLimits``.
    static func decodeUsage(_ data: Data, fetchedAt: Date) throws -> SubscriptionLimits {
        struct Response: Decodable {
            let fiveHour: Window?
            let sevenDay: Window?
            struct Window: Decodable {
                let utilization: Double?
                let resetsAt: String?
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
                utilization: window?.utilization ?? 0,
                resetsAt: window?.resetsAt.flatMap(Self.parseDate)
            )
        }
        return SubscriptionLimits(
            fiveHour: limit(decoded.fiveHour),
            sevenDay: limit(decoded.sevenDay),
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
