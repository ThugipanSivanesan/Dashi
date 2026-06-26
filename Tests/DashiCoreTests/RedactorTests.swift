import XCTest

@testable import DashiCore

final class RedactorTests: XCTestCase {
    func testRedactsOpenAIKeyShape() {
        let redactor = Redactor()
        let masked = redactor.redact("key=sk-abcdef0123456789ABCDEF done")  // gitleaks:allow
        XCTAssertFalse(masked.contains("sk-abcdef0123456789"))
        XCTAssertTrue(masked.contains("***"))
    }

    func testRedactsAnthropicKeyShape() {
        let key = "sk-ant-api03-abcDEF0123456789xyz"  // gitleaks:allow
        let masked = Redactor().redact("using \(key) now")
        XCTAssertFalse(masked.contains("sk-ant-api03"))
    }

    func testRedactsBearerToken() {
        let redactor = Redactor()
        let masked = redactor.redact("Authorization: Bearer abc.def-123_XYZ")
        XCTAssertFalse(masked.contains("abc.def-123_XYZ"))
    }

    func testRedactsHex64() {
        let hex = String(repeating: "a1b2c3d4", count: 8)  // 64 hex chars
        let masked = Redactor().redact("token \(hex) end")
        XCTAssertFalse(masked.contains(hex))
    }

    func testRedactsExactSeededSecret() {
        let secret = "this-exact-value-has-no-recognisable-shape"
        let redactor = Redactor(seedSecrets: [secret])
        let masked = redactor.redact("leaked: \(secret) oops")
        XCTAssertFalse(masked.contains(secret))
        XCTAssertEqual(masked, "leaked: *** oops")
    }

    func testLeavesOrdinaryTextUntouched() {
        let text = "Usage for today: 1234 input, 567 output tokens."
        XCTAssertEqual(Redactor().redact(text), text)
    }
}
