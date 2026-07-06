import XCTest

@testable import DashiCore

final class CodexCredentialsTests: XCTestCase {
    func testParsesTokensAndAccountId() throws {
        let json = """
            {"OPENAI_API_KEY":null,
             "tokens":{"id_token":"eyJ...","access_token":"access-xyz",
                       "refresh_token":"refresh-abc","account_id":"account-123"},
             "last_refresh":"2025-12-28T12:34:56Z"}
            """
        let token = try XCTUnwrap(CodexCredentialsReader.parse(Data(json.utf8)))
        XCTAssertEqual(token.accessToken.reveal(), "access-xyz")
        XCTAssertEqual(token.accountId, "account-123")
        XCTAssertEqual(token.refreshToken?.reveal(), "refresh-abc")
        XCTAssertNotNil(token.lastRefresh)
    }

    func testParsesFractionalSecondsLastRefresh() throws {
        let json = """
            {"tokens":{"access_token":"a"},"last_refresh":"2025-12-28T12:34:56.789Z"}
            """
        let token = try XCTUnwrap(CodexCredentialsReader.parse(Data(json.utf8)))
        XCTAssertNotNil(token.lastRefresh)
    }

    func testReturnsNilWithoutAccessToken() throws {
        // API-key-only file: no Bearer access token → treated as not signed in.
        let json = #"{"OPENAI_API_KEY":"sk-abc","tokens":{"account_id":"account-1"}}"#
        XCTAssertNil(try CodexCredentialsReader.parse(Data(json.utf8)))
    }

    func testReturnsNilOnEmptyAccessToken() throws {
        XCTAssertNil(
            try CodexCredentialsReader.parse(Data(#"{"tokens":{"access_token":""}}"#.utf8)))
    }

    func testDefaultAuthFileHonoursCodexHome() {
        let url = CodexCredentialsReader.defaultAuthFileURL(
            environment: ["CODEX_HOME": "/tmp/codex-home"],
            home: URL(fileURLWithPath: "/Users/example"))
        XCTAssertEqual(url.path, "/tmp/codex-home/auth.json")
    }

    func testDefaultAuthFileFallsBackToHomeDotCodex() {
        let url = CodexCredentialsReader.defaultAuthFileURL(
            environment: [:], home: URL(fileURLWithPath: "/Users/example"))
        XCTAssertEqual(url.path, "/Users/example/.codex/auth.json")
    }

    func testIsStaleWhenNoLastRefresh() {
        let token = CodexOAuthToken(accessToken: Secret("a"))
        XCTAssertTrue(token.isStale())
    }

    func testIsStaleAfterEightDays() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let fresh = CodexOAuthToken(
            accessToken: Secret("a"), lastRefresh: now.addingTimeInterval(-3600))
        let old = CodexOAuthToken(
            accessToken: Secret("a"), lastRefresh: now.addingTimeInterval(-9 * 24 * 3600))
        XCTAssertFalse(fresh.isStale(now: now))
        XCTAssertTrue(old.isStale(now: now))
    }

    func testReaderReturnsNilWhenFileMissing() throws {
        let reader = CodexCredentialsReader(
            fileURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/auth.json"))
        XCTAssertNil(try reader.currentToken())
    }
}
