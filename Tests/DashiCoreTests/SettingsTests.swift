import XCTest

@testable import DashiCore

final class SettingsTests: XCTestCase {
    func testDefaultsAreSafe() {
        let settings = Settings()
        XCTAssertEqual(settings.pollInterval, 300)
    }

    func testPollIntervalIsClampedToPositive() {
        XCTAssertEqual(Settings(pollInterval: -5).pollInterval, 1)
    }

    func testFromEnvironmentParsesValidValues() {
        let settings = Settings.fromEnvironment([
            "DASHI_POLL_INTERVAL": "60"
        ])
        XCTAssertEqual(settings.pollInterval, 60)
    }

    func testFromEnvironmentIgnoresInvalidValues() {
        let settings = Settings.fromEnvironment([
            "DASHI_POLL_INTERVAL": "abc"
        ])
        XCTAssertEqual(settings.pollInterval, 300)
    }
}
