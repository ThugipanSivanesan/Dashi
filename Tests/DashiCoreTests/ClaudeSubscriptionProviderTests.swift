import XCTest

@testable import DashiCore

final class ClaudeSubscriptionProviderTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func http(
        _ status: Int, body: String = "", headers: [String: String]? = nil
    ) -> HTTPTransport {
        { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
                statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }

    private func provider(
        credentials: any ClaudeCredentialsReading, transport: @escaping HTTPTransport
    )
        -> ClaudeSubscriptionProvider
    {
        let epoch = epoch
        return ClaudeSubscriptionProvider(
            credentials: credentials, transport: transport, now: { epoch })
    }

    func testDecodeUsageParsesWindows() throws {
        let json = """
            {"five_hour":{"utilization":73,"resets_at":"2026-06-29T19:42:00Z"},
             "seven_day":{"utilization":41.5,"resets_at":null}}
            """
        let limits = try ClaudeSubscriptionProvider.decodeUsage(Data(json.utf8), fetchedAt: epoch)
        let fiveHour = try XCTUnwrap(limits.fiveHour)
        let sevenDay = try XCTUnwrap(limits.sevenDay)
        XCTAssertEqual(fiveHour.utilization, 73)
        XCTAssertNotNil(fiveHour.resetsAt)
        XCTAssertEqual(sevenDay.utilization, 41.5)
        XCTAssertNil(sevenDay.resetsAt)
        XCTAssertEqual(limits.fetchedAt, epoch)
    }

    func testDecodesRealWorldMicrosecondTimestamps() throws {
        // Shape returned by the live endpoint: microsecond fractional seconds + "+00:00" offset,
        // plus extra fields we ignore.
        let json = """
            {"five_hour":{"utilization":29.0,"resets_at":"2026-06-29T11:00:00.968660+00:00",
             "limit_dollars":null},"seven_day":{"utilization":3.0,
             "resets_at":"2026-07-06T03:00:00.968681+00:00"},"member_dashboard_available":false}
            """
        let limits = try ClaudeSubscriptionProvider.decodeUsage(Data(json.utf8), fetchedAt: epoch)
        let fiveHour = try XCTUnwrap(limits.fiveHour)
        let sevenDay = try XCTUnwrap(limits.sevenDay)
        XCTAssertEqual(fiveHour.utilization, 29)
        let reset = try XCTUnwrap(fiveHour.resetsAt)
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-29T11:00:00Z"))
        XCTAssertEqual(reset.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(sevenDay.utilization, 3)
        XCTAssertNotNil(sevenDay.resetsAt)
    }

    func testNotSignedInWhenNoToken() async {
        let provider = provider(
            credentials: StubCredentialsReader(token: nil), transport: http(200))
        await assertThrows(provider) { XCTAssertEqual($0, .notSignedIn) }
    }

    func testNeedsReauthOn401() async {
        let token = ClaudeOAuthToken(accessToken: Secret("t"), expiresAt: nil)
        let provider = provider(
            credentials: StubCredentialsReader(token: token), transport: http(401))
        await assertThrows(provider) { XCTAssertEqual($0, .needsReauth) }
    }

    func testRequestFailedOnServerError() async {
        let token = ClaudeOAuthToken(accessToken: Secret("t"), expiresAt: nil)
        let provider = provider(
            credentials: StubCredentialsReader(token: token), transport: http(500))
        await assertThrows(provider) {
            guard case .requestFailed = $0 else { return XCTFail("expected requestFailed") }
        }
    }

    func testRateLimitedOn429WithRetryAfter() async {
        let token = ClaudeOAuthToken(accessToken: Secret("t"), expiresAt: nil)
        let provider = provider(
            credentials: StubCredentialsReader(token: token),
            transport: http(429, headers: ["Retry-After": "120"]))
        await assertThrows(provider) { XCTAssertEqual($0, .rateLimited(retryAfter: 120)) }
    }

    func testRateLimitedOn429WithoutRetryAfter() async {
        let token = ClaudeOAuthToken(accessToken: Secret("t"), expiresAt: nil)
        let provider = provider(
            credentials: StubCredentialsReader(token: token), transport: http(429))
        await assertThrows(provider) { XCTAssertEqual($0, .rateLimited(retryAfter: nil)) }
    }

    func testSuccessReturnsLimits() async throws {
        let token = ClaudeOAuthToken(accessToken: Secret("t"), expiresAt: nil)
        let body =
            #"{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":5,"resets_at":null}}"#
        let provider = provider(
            credentials: StubCredentialsReader(token: token), transport: http(200, body: body))
        let limits = try await provider.currentLimits()
        let fiveHour = try XCTUnwrap(limits.fiveHour)
        XCTAssertEqual(fiveHour.utilization, 10)
    }

    func testSendsBearerAndBetaHeaders() async throws {
        let token = ClaudeOAuthToken(accessToken: Secret("secret-token"), expiresAt: nil)
        let captured = HeaderCapture()
        let transport: HTTPTransport = { request in
            await captured.set(request.allHTTPHeaderFields ?? [:])
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body =
                #"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":0,"resets_at":null}}"#
            return (Data(body.utf8), response)
        }
        _ = try await provider(
            credentials: StubCredentialsReader(token: token), transport: transport
        )
        .currentLimits()
        let headers = await captured.headers
        XCTAssertEqual(headers["Authorization"], "Bearer secret-token")
        XCTAssertEqual(headers["anthropic-beta"], "oauth-2025-04-20")
    }

    func testRejectsNonAllowlistedEndpointBeforeSendingToken() async {
        let epoch = epoch
        let token = ClaudeOAuthToken(accessToken: Secret("t"), expiresAt: nil)
        let mustNotRun: HTTPTransport = { _ in
            XCTFail("transport must not run for a rejected endpoint")
            throw LimitError.notSignedIn
        }
        for bad in [
            "http://api.anthropic.com/api/oauth/usage",  // plaintext scheme
            "https://evil.example.com/api/oauth/usage",  // wrong host
        ] {
            let provider = ClaudeSubscriptionProvider(
                credentials: StubCredentialsReader(token: token),
                transport: mustNotRun,
                endpoint: URL(string: bad)!,
                now: { epoch })
            await assertThrows(provider) {
                guard case .requestFailed = $0 else {
                    return XCTFail("expected requestFailed for \(bad)")
                }
            }
        }
    }

    // MARK: - Helpers

    private actor HeaderCapture {
        var headers: [String: String] = [:]
        func set(_ value: [String: String]) { headers = value }
    }

    private func assertThrows(
        _ provider: ClaudeSubscriptionProvider,
        _ check: (LimitError) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await provider.currentLimits()
            XCTFail("expected throw", file: file, line: line)
        } catch let error as LimitError {
            check(error)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}
