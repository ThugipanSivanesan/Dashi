import XCTest

@testable import DashiCore

final class CodexSubscriptionProviderTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func http(
        _ status: Int, body: String = "", headers: [String: String]? = nil
    ) -> HTTPTransport {
        { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }

    private func provider(
        credentials: any CodexCredentialsReading, transport: @escaping HTTPTransport
    ) -> CodexSubscriptionProvider {
        let epoch = epoch
        return CodexSubscriptionProvider(
            credentials: credentials, transport: transport, now: { epoch })
    }

    private func token(accountId: String? = nil) -> CodexOAuthToken {
        CodexOAuthToken(accessToken: Secret("t"), accountId: accountId)
    }

    func testDecodeUsageMapsPrimaryAndSecondaryWindows() throws {
        // reset_at is epoch seconds; primary → 5-hour, secondary → weekly.
        let json = """
            {"plan_type":"pro","rate_limit":{
              "primary_window":{"used_percent":41,"reset_at":1000900,"limit_window_seconds":18000},
              "secondary_window":{"used_percent":12.5,"reset_at":1600000,"limit_window_seconds":604800}}}
            """
        let limits = try CodexSubscriptionProvider.decodeUsage(Data(json.utf8), fetchedAt: epoch)
        XCTAssertEqual(limits.fiveHour.utilization, 41)
        XCTAssertEqual(limits.fiveHour.resetsAt, Date(timeIntervalSince1970: 1_000_900))
        XCTAssertEqual(limits.sevenDay.utilization, 12.5)
        XCTAssertEqual(limits.sevenDay.resetsAt, Date(timeIntervalSince1970: 1_600_000))
        XCTAssertEqual(limits.fetchedAt, epoch)
    }

    func testDecodeUsageToleratesMissingWindows() throws {
        // Absent rate_limit / windows fail closed to 0% with no reset, like the Claude decoder.
        let limits = try CodexSubscriptionProvider.decodeUsage(
            Data(#"{"plan_type":"free"}"#.utf8), fetchedAt: epoch)
        XCTAssertEqual(limits.fiveHour.utilization, 0)
        XCTAssertNil(limits.fiveHour.resetsAt)
        XCTAssertEqual(limits.sevenDay.utilization, 0)
        XCTAssertNil(limits.sevenDay.resetsAt)
    }

    func testNotSignedInWhenNoToken() async {
        let provider = provider(
            credentials: StubCodexCredentialsReader(token: nil), transport: http(200))
        await assertThrows(provider) { XCTAssertEqual($0, .notSignedIn) }
    }

    func testNeedsReauthOn401() async {
        let provider = provider(
            credentials: StubCodexCredentialsReader(token: token()), transport: http(401))
        await assertThrows(provider) { XCTAssertEqual($0, .needsReauth) }
    }

    func testNeedsReauthOn403() async {
        let provider = provider(
            credentials: StubCodexCredentialsReader(token: token()), transport: http(403))
        await assertThrows(provider) { XCTAssertEqual($0, .needsReauth) }
    }

    func testRequestFailedOnServerError() async {
        let provider = provider(
            credentials: StubCodexCredentialsReader(token: token()), transport: http(500))
        await assertThrows(provider) {
            guard case .requestFailed = $0 else { return XCTFail("expected requestFailed") }
        }
    }

    func testRateLimitedOn429WithRetryAfter() async {
        let provider = provider(
            credentials: StubCodexCredentialsReader(token: token()),
            transport: http(429, headers: ["Retry-After": "45"]))
        await assertThrows(provider) { XCTAssertEqual($0, .rateLimited(retryAfter: 45)) }
    }

    func testRateLimitedOn429WithoutRetryAfter() async {
        let provider = provider(
            credentials: StubCodexCredentialsReader(token: token()), transport: http(429))
        await assertThrows(provider) { XCTAssertEqual($0, .rateLimited(retryAfter: nil)) }
    }

    func testSuccessReturnsLimits() async throws {
        let body = #"""
            {"rate_limit":{"primary_window":{"used_percent":10,"reset_at":null},
             "secondary_window":{"used_percent":5,"reset_at":null}}}
            """#
        let provider = provider(
            credentials: StubCodexCredentialsReader(token: token()),
            transport: http(200, body: body))
        let limits = try await provider.currentLimits()
        XCTAssertEqual(limits.fiveHour.utilization, 10)
        XCTAssertEqual(limits.sevenDay.utilization, 5)
    }

    func testSendsBearerUserAgentAndAccountHeaders() async throws {
        let captured = HeaderCapture()
        let transport: HTTPTransport = { request in
            await captured.set(request.allHTTPHeaderFields ?? [:])
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"rate_limit":{}}"#.utf8), response)
        }
        _ = try await provider(
            credentials: StubCodexCredentialsReader(
                token: CodexOAuthToken(accessToken: Secret("secret-token"), accountId: "acct-1")),
            transport: transport
        ).currentLimits()
        let headers = await captured.headers
        XCTAssertEqual(headers["Authorization"], "Bearer secret-token")
        XCTAssertEqual(headers["ChatGPT-Account-Id"], "acct-1")
        XCTAssertEqual(headers["User-Agent"], "Dashi")
    }

    func testOmitsAccountHeaderWhenAbsent() async throws {
        let captured = HeaderCapture()
        let transport: HTTPTransport = { request in
            await captured.set(request.allHTTPHeaderFields ?? [:])
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"rate_limit":{}}"#.utf8), response)
        }
        _ = try await provider(
            credentials: StubCodexCredentialsReader(token: token(accountId: nil)),
            transport: transport
        ).currentLimits()
        let headers = await captured.headers
        XCTAssertNil(headers["ChatGPT-Account-Id"])
    }

    func testRejectsNonAllowlistedEndpointBeforeSendingToken() async {
        let epoch = epoch
        let mustNotRun: HTTPTransport = { _ in
            XCTFail("transport must not run for a rejected endpoint")
            throw LimitError.notSignedIn
        }
        for bad in [
            "http://chatgpt.com/backend-api/wham/usage",  // plaintext scheme
            "https://evil.example.com/backend-api/wham/usage",  // wrong host
        ] {
            let provider = CodexSubscriptionProvider(
                credentials: StubCodexCredentialsReader(token: token()),
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
        _ provider: CodexSubscriptionProvider,
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
