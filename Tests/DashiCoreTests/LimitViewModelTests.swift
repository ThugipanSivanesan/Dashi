import XCTest

@testable import DashiCore

private struct StubLimitProvider: LimitProvider {
    let result: Result<SubscriptionLimits, LimitError>
    func currentLimits() async throws -> SubscriptionLimits { try result.get() }
}

@MainActor
final class LimitViewModelTests: XCTestCase {
    private func limits() -> SubscriptionLimits {
        SubscriptionLimits(
            fiveHour: RollingLimit(utilization: 50, resetsAt: nil),
            sevenDay: RollingLimit(utilization: 20, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 0))
    }

    func testLoadedOnSuccess() async {
        let viewModel = LimitViewModel(provider: StubLimitProvider(result: .success(limits())))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded(limits()))
    }

    func testNotSignedIn() async {
        let viewModel = LimitViewModel(provider: StubLimitProvider(result: .failure(.notSignedIn)))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .notSignedIn)
    }

    func testNeedsReauth() async {
        let viewModel = LimitViewModel(provider: StubLimitProvider(result: .failure(.needsReauth)))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .needsReauth)
    }

    func testFailedSurfacesMessage() async {
        let viewModel = LimitViewModel(
            provider: StubLimitProvider(result: .failure(.requestFailed("nope"))))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .failed("nope"))
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
