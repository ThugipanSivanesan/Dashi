import XCTest

@testable import DashiCore

/// Exercises the ``SecretStore`` contract against the in-memory implementation so tests never
/// touch the real Keychain (which is unavailable on headless CI).
final class SecretStoreTests: XCTestCase {
    func testSetGetRoundTrip() throws {
        let store = InMemorySecretStore()
        try store.set(Secret("key-123"), for: "anthropic")
        XCTAssertEqual(try store.get("anthropic")?.reveal(), "key-123")
    }

    func testGetMissingReturnsNil() throws {
        XCTAssertNil(try InMemorySecretStore().get("nope"))
    }

    func testSetOverwrites() throws {
        let store = InMemorySecretStore()
        try store.set(Secret("old"), for: "openai")
        try store.set(Secret("new"), for: "openai")
        XCTAssertEqual(try store.get("openai")?.reveal(), "new")
    }

    func testDeleteRemoves() throws {
        let store = InMemorySecretStore(["openai": "key"])
        try store.delete("openai")
        XCTAssertNil(try store.get("openai"))
    }

    func testDeleteMissingIsNoError() throws {
        XCTAssertNoThrow(try InMemorySecretStore().delete("absent"))
    }
}
