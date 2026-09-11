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

final class ClaudeUsageDecodingTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

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

    /// Reads the session and weekly_all percentages out of the top-level `limits` array when the
    /// payload carries no legacy `five_hour` / `seven_day` keys.
    func testDecodeUsageReadsSessionAndWeeklyFromLimitsArray() throws {
        let json = """
            {"limits":[
             {"kind":"session","group":"session","percent":12,"resets_at":null,"scope":null},
             {"kind":"weekly_all","group":"weekly","percent":47,"resets_at":null,"scope":null},
             {"kind":"weekly_scoped","group":"weekly","percent":83,"resets_at":null,
              "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}
            """
        let limits = try ClaudeSubscriptionProvider.decodeUsage(Data(json.utf8), fetchedAt: epoch)
        XCTAssertEqual(try XCTUnwrap(limits.fiveHour).utilization, 12)
        XCTAssertEqual(try XCTUnwrap(limits.sevenDay).utilization, 47)
    }

    /// Decodes every `limits` entry into a window in payload order, taking percentages from
    /// `percent` and the scoped window's title from `scope.model.display_name`.
    func testDecodesEveryLimitsEntryIntoAWindowInPayloadOrder() throws {
        let json = """
            {"limits":[
             {"kind":"session","group":"session","percent":12,"resets_at":null,"scope":null},
             {"kind":"weekly_all","group":"weekly","percent":47,"resets_at":null,"scope":null},
             {"kind":"weekly_scoped","group":"weekly","percent":83,
              "resets_at":"2026-09-15T05:00:00.123456+00:00",
              "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}
            """
        let limits = try ClaudeSubscriptionProvider.decodeUsage(Data(json.utf8), fetchedAt: epoch)
        XCTAssertEqual(limits.windows.map(\.kind), [.session, .weekly, .weeklyScoped])
        XCTAssertEqual(limits.windows.map(\.title), ["5-hour", "Weekly", "Fable"])
        XCTAssertEqual(limits.windows.map(\.limit.utilization), [12, 47, 83])
        XCTAssertEqual(try XCTUnwrap(limits.sevenDay).utilization, 47)
        let reset = try XCTUnwrap(limits.windows.last?.limit.resetsAt)
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-15T05:00:00Z"))
        XCTAssertEqual(reset.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1.0)
    }

    /// Takes all three windows from the `limits` array for a payload that also carries legacy
    /// `five_hour` and `seven_day` keys holding different percentages.
    func testLimitsArrayTakesPrecedenceOverLegacyKeys() throws {
        let json = """
            {"five_hour":{"utilization":98,"resets_at":null},
             "seven_day":{"utilization":99,"resets_at":null},
             "limits":[
             {"kind":"session","group":"session","percent":12,"resets_at":null,"scope":null},
             {"kind":"weekly_all","group":"weekly","percent":47,"resets_at":null,"scope":null},
             {"kind":"weekly_scoped","group":"weekly","percent":83,"resets_at":null,
              "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}
            """
        let limits = try ClaudeSubscriptionProvider.decodeUsage(Data(json.utf8), fetchedAt: epoch)
        XCTAssertEqual(limits.windows.map(\.title), ["5-hour", "Weekly", "Fable"])
        XCTAssertEqual(limits.windows.map(\.limit.utilization), [12, 47, 83])
    }

    /// Yields only the session and weekly windows, with no placeholder third row, when the `limits`
    /// array carries no `weekly_scoped` entry.
    func testLimitsArrayWithoutScopedEntryYieldsTwoWindows() throws {
        let json = """
            {"limits":[
             {"kind":"session","group":"session","percent":12,"resets_at":null,"scope":null},
             {"kind":"weekly_all","group":"weekly","percent":47,"resets_at":null,"scope":null}]}
            """
        let limits = try ClaudeSubscriptionProvider.decodeUsage(Data(json.utf8), fetchedAt: epoch)
        XCTAssertEqual(limits.windows.map(\.kind), [.session, .weekly])
        XCTAssertEqual(limits.windows.map(\.title), ["5-hour", "Weekly"])
    }

    /// Falls back to the legacy `five_hour` and `seven_day` keys, titled "5-hour" and "Weekly", for
    /// a payload that carries no `limits` array.
    func testLegacyPayloadWithoutLimitsArrayYieldsTheTwoNamedWindows() throws {
        let json = """
            {"five_hour":{"utilization":73,"resets_at":null},
             "seven_day":{"utilization":41.5,"resets_at":null}}
            """
        let limits = try ClaudeSubscriptionProvider.decodeUsage(Data(json.utf8), fetchedAt: epoch)
        XCTAssertEqual(limits.windows.map(\.kind), [.session, .weekly])
        XCTAssertEqual(limits.windows.map(\.title), ["5-hour", "Weekly"])
        XCTAssertEqual(limits.windows.map(\.limit.utilization), [73, 41.5])
    }

    /// Reports a legacy payload carrying only `five_hour` as a single window and a nil `sevenDay`,
    /// rather than as a 0% weekly window.
    func testAbsentLegacyWindowYieldsNoWindowRatherThanZeroPercent() throws {
        let json = #"{"five_hour":{"utilization":73,"resets_at":null}}"#
        let limits = try ClaudeSubscriptionProvider.decodeUsage(Data(json.utf8), fetchedAt: epoch)
        XCTAssertEqual(limits.windows.map(\.kind), [.session])
        XCTAssertNil(limits.sevenDay)
        XCTAssertEqual(try XCTUnwrap(limits.fiveHour).utilization, 73)
    }

    /// Resolves `sevenDay` to the `weekly_all` window when a higher-percentage scoped window
    /// precedes it in the `limits` array.
    func testSevenDayResolvesToWeeklyAllRatherThanAScopedWindow() throws {
        let json = """
            {"limits":[
             {"kind":"weekly_scoped","group":"weekly","percent":83,"resets_at":null,
              "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}},
             {"kind":"weekly_all","group":"weekly","percent":47,"resets_at":null,"scope":null}]}
            """
        let limits = try ClaudeSubscriptionProvider.decodeUsage(Data(json.utf8), fetchedAt: epoch)
        XCTAssertEqual(try XCTUnwrap(limits.sevenDay).utilization, 47)
        XCTAssertNil(limits.fiveHour)
    }

    /// Drops an entry with an unrecognised or absent `kind`, and a `weekly_scoped` entry with a
    /// null scope or a null `display_name`, keeping the rest of the array rather than failing it.
    func testDropsUnrecognisedKindsAndScopedEntriesWithoutADisplayName() throws {
        let session = """
            {"kind":"session","group":"session","percent":12,"resets_at":null,"scope":null}
            """
        let dropped = [
            """
            {"kind":"monthly_all","group":"monthly","percent":9,"resets_at":null,"scope":null}
            """,
            """
            {"group":"weekly","percent":9,"resets_at":null,"scope":null}
            """,
            """
            {"kind":"weekly_scoped","group":"weekly","percent":83,"resets_at":null,"scope":null}
            """,
            """
            {"kind":"weekly_scoped","group":"weekly","percent":83,"resets_at":null,
             "scope":{"model":{"id":null,"display_name":null},"surface":null}}
            """,
        ]
        for entry in dropped {
            let json = "{\"limits\":[\(session),\(entry)]}"
            let limits = try ClaudeSubscriptionProvider.decodeUsage(
                Data(json.utf8), fetchedAt: epoch)
            XCTAssertEqual(limits.windows.map(\.kind), [.session], "kept \(entry)")
        }
    }

    /// Keeps the valid session window when a sibling `limits` entry carries a string `percent`, a
    /// string `scope`, or is null, a bare string or a bare number rather than an object.
    func testKeepsValidEntriesWhenASiblingEntryFailsToDecode() throws {
        let session = """
            {"kind":"session","group":"session","percent":12,"resets_at":null,"scope":null}
            """
        let malformed = [
            """
            {"kind":"weekly_all","group":"weekly","percent":"12","resets_at":null,"scope":null}
            """,
            """
            {"kind":"weekly_all","group":"weekly","percent":9,"resets_at":null,"scope":"fable"}
            """,
            "null",
            "\"weekly_all\"",
            "9",
        ]
        for entry in malformed {
            let json = "{\"limits\":[\(session),\(entry)]}"
            let limits = try ClaudeSubscriptionProvider.decodeUsage(
                Data(json.utf8), fetchedAt: epoch)
            XCTAssertEqual(limits.windows.map(\.kind), [.session], "kept \(entry)")
        }
    }

    /// Falls back to the legacy `five_hour` and `seven_day` windows when `limits` is an object
    /// rather than an array.
    func testFallsBackToLegacyKeysWhenLimitsIsNotAnArray() throws {
        let json = """
            {"five_hour":{"utilization":73,"resets_at":null},
             "seven_day":{"utilization":41.5,"resets_at":null},
             "limits":{"session":{"percent":12}}}
            """
        let limits = try ClaudeSubscriptionProvider.decodeUsage(Data(json.utf8), fetchedAt: epoch)
        XCTAssertEqual(limits.windows.map(\.kind), [.session, .weekly])
        XCTAssertEqual(limits.windows.map(\.limit.utilization), [73, 41.5])
    }
}
