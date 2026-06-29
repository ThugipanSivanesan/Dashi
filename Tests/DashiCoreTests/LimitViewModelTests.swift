import XCTest

@testable import DashiCore

private struct StubLimitProvider: LimitProvider {
    let result: Result<SubscriptionLimits, LimitError>
    func currentLimits() async throws -> SubscriptionLimits { try result.get() }
}

/// Provider that fails the test if it's ever called — used to prove the consent gate short-circuits
/// before the token is touched.
private struct UnusedLimitProvider: LimitProvider {
    func currentLimits() async throws -> SubscriptionLimits {
        XCTFail("provider should not be called without consent")
        throw LimitError.notSignedIn
    }
}

@MainActor
final class LimitViewModelTests: XCTestCase {
    private func limits() -> SubscriptionLimits {
        SubscriptionLimits(
            fiveHour: RollingLimit(utilization: 50, resetsAt: nil),
            sevenDay: RollingLimit(utilization: 20, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 0))
    }

    /// Builds a view model with consent already granted so tests focus on load behaviour.
    private func consented(_ result: Result<SubscriptionLimits, LimitError>) -> LimitViewModel {
        LimitViewModel(
            provider: StubLimitProvider(result: result), consent: InMemoryConsentStore(true))
    }

    func testLoadedOnSuccess() async {
        let viewModel = consented(.success(limits()))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded(limits()))
    }

    func testNotSignedIn() async {
        let viewModel = consented(.failure(.notSignedIn))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .notSignedIn)
    }

    func testNeedsReauth() async {
        let viewModel = consented(.failure(.needsReauth))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .needsReauth)
    }

    func testFailedSurfacesMessage() async {
        let viewModel = consented(.failure(.requestFailed("nope")))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .failed("nope"))
    }

    func testStartsNeedingConsentWhenNotGranted() {
        let viewModel = LimitViewModel(
            provider: UnusedLimitProvider(), consent: InMemoryConsentStore(false))
        XCTAssertEqual(viewModel.state, .needsConsent)
    }

    func testLoadDoesNotTouchProviderWithoutConsent() async {
        let viewModel = LimitViewModel(
            provider: UnusedLimitProvider(), consent: InMemoryConsentStore(false))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .needsConsent)
    }

    func testGrantConsentPersistsAndLoads() async {
        let store = InMemoryConsentStore(false)
        let viewModel = LimitViewModel(
            provider: StubLimitProvider(result: .success(limits())), consent: store)
        await viewModel.grantConsent()
        XCTAssertTrue(store.hasConsented())
        XCTAssertEqual(viewModel.state, .loaded(limits()))
    }
}

final class ResetCountdownTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testHoursAndMinutes() {
        XCTAssertEqual(
            resetCountdown(to: now.addingTimeInterval(2 * 3600 + 13 * 60), now: now), "2h 13m")
    }

    func testMinutesOnly() {
        XCTAssertEqual(resetCountdown(to: now.addingTimeInterval(47 * 60), now: now), "47m")
    }

    func testPastIsNow() {
        XCTAssertEqual(resetCountdown(to: now.addingTimeInterval(-60), now: now), "now")
    }

    func testNilIsDash() {
        XCTAssertEqual(resetCountdown(to: nil, now: now), "—")
    }
}

final class ResetDayTimeTests: XCTestCase {
    // Pin to UTC so today/tomorrow day arithmetic is deterministic regardless of the host timezone.
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
    // 1970-01-12 13:46:40 UTC — mid-day, so ±a few hours stays inside the same UTC day.
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testNilIsDash() {
        XCTAssertEqual(resetDayTime(to: nil, now: now, calendar: calendar), "—")
    }

    func testLaterTodayIsToday() {
        let result = resetDayTime(
            to: now.addingTimeInterval(3 * 3600), now: now, calendar: calendar)
        XCTAssertTrue(result.hasPrefix("today at "), result)
    }

    func testTomorrow() {
        let result = resetDayTime(
            to: now.addingTimeInterval(28 * 3600), now: now, calendar: calendar)
        XCTAssertTrue(result.hasPrefix("tomorrow at "), result)
    }

    func testSeveralDaysOutShowsWeekday() {
        let result = resetDayTime(
            to: now.addingTimeInterval(4 * 24 * 3600), now: now, calendar: calendar)
        XCTAssertFalse(result.hasPrefix("today"), result)
        XCTAssertFalse(result.hasPrefix("tomorrow"), result)
        XCTAssertTrue(result.contains(" at "), result)
    }
}
