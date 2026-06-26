import XCTest

@testable import DashiCore

final class SecretTests: XCTestCase {
    func testDescriptionNeverRevealsPlaintext() {
        let secret = Secret("sk-ant-supersecretvalue1234567890")  // gitleaks:allow
        XCTAssertEqual(secret.description, "***")
        XCTAssertEqual(secret.debugDescription, "Secret(***)")
        XCTAssertEqual("\(secret)", "***")
        XCTAssertFalse("\(secret)".contains("supersecret"))
    }

    func testRevealReturnsPlaintext() {
        let secret = Secret("plaintext-key")
        XCTAssertEqual(secret.reveal(), "plaintext-key")
    }

    func testIsEmpty() {
        XCTAssertTrue(Secret("").isEmpty)
        XCTAssertFalse(Secret("x").isEmpty)
    }
}
