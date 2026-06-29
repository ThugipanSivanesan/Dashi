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
