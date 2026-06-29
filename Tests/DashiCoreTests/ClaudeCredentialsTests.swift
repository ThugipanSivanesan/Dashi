import XCTest

@testable import DashiCore

final class ClaudeCredentialsTests: XCTestCase {
    func testParsesAccessTokenAndExpiry() throws {
        // Fixture uses a non-key-shaped token so secret scanners don't flag it.
        let json = """
            {"claudeAiOauth":{"accessToken":"test-oauth-access-token","expiresAt":1735500000000,"scopes":["user:inference"],"subscriptionType":"max"}}
            """
        let token = try XCTUnwrap(ClaudeCredentialsReader.parse(Data(json.utf8)))
        XCTAssertEqual(token.accessToken.reveal(), "test-oauth-access-token")
        // 1735500000000 ms → seconds
        XCTAssertEqual(token.expiresAt, Date(timeIntervalSince1970: 1_735_500_000))
    }

    func testParsesExpiryInSeconds() throws {
        let json = """
            {"claudeAiOauth":{"accessToken":"tok","expiresAt":1735500000}}
            """
        let token = try XCTUnwrap(ClaudeCredentialsReader.parse(Data(json.utf8)))
        XCTAssertEqual(token.expiresAt, Date(timeIntervalSince1970: 1_735_500_000))
    }

    func testEmptyTokenIsNil() throws {
        let json = #"{"claudeAiOauth":{"accessToken":""}}"#
        XCTAssertNil(try ClaudeCredentialsReader.parse(Data(json.utf8)))
    }

    func testMissingOAuthIsNil() throws {
        XCTAssertNil(try ClaudeCredentialsReader.parse(Data(#"{}"#.utf8)))
    }

    func testIsExpired() {
        let past = ClaudeOAuthToken(
            accessToken: Secret("x"), expiresAt: Date(timeIntervalSince1970: 0))
        let future = ClaudeOAuthToken(
            accessToken: Secret("x"), expiresAt: Date(timeIntervalSinceNow: 3600))
        let none = ClaudeOAuthToken(accessToken: Secret("x"), expiresAt: nil)
        XCTAssertTrue(past.isExpired())
        XCTAssertFalse(future.isExpired())
        XCTAssertFalse(none.isExpired())
    }
}
