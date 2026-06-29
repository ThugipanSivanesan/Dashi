import XCTest

@testable import DashiCore

/// Verifies the Keychain write queries without touching the real Keychain (which is unavailable on
/// headless CI). The round-trip behaviour of the store is covered via `InMemorySecretStore` in
/// `SecretStoreTests`.
final class KeychainStoreTests: XCTestCase {
    private let expected = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String

    func testAddQueryPinsAccessibilityToThisDeviceOnly() {
        let query = KeychainStore(service: "com.dashi.test")
            .addQuery(for: "anthropic", data: Data("x".utf8))
        XCTAssertEqual(query[kSecAttrAccessible as String] as? String, expected)
        XCTAssertNotNil(query[kSecValueData as String])
    }

    func testUpdateAttributesPinAccessibility() {
        let attrs = KeychainStore().updateAttributes(data: Data("x".utf8))
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String, expected)
    }
}
