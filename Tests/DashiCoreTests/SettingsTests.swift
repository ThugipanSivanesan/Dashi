import XCTest

@testable import DashiCore

final class SettingsTests: XCTestCase {
    func testDefaultsAreOfflineAndSafe() {
        let settings = Settings()
        XCTAssertEqual(settings.providerMode, .offline)
        XCTAssertEqual(settings.pollInterval, 120)
    }

    func testPollIntervalIsClampedToPositive() {
        XCTAssertEqual(Settings(pollInterval: -5).pollInterval, 1)
    }

    func testFromEnvironmentParsesValidValues() {
        let settings = Settings.fromEnvironment([
            "DASHI_PROVIDER_MODE": "anthropic",
            "DASHI_POLL_INTERVAL": "60",
        ])
        XCTAssertEqual(settings.providerMode, .anthropic)
        XCTAssertEqual(settings.pollInterval, 60)
    }

    func testFromEnvironmentIgnoresInvalidValues() {
        let settings = Settings.fromEnvironment([
            "DASHI_PROVIDER_MODE": "not-a-mode",
            "DASHI_POLL_INTERVAL": "abc",
        ])
        XCTAssertEqual(settings.providerMode, .offline)
        XCTAssertEqual(settings.pollInterval, 120)
    }
}
