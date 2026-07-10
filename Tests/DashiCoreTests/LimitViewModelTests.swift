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

/// Returns a different result on each call so tests can drive success-then-failure sequences.
/// The last element repeats once exhausted.
private actor SequenceLimitProvider: LimitProvider {
    private let results: [Result<SubscriptionLimits, LimitError>]
    private var index = 0
    init(_ results: [Result<SubscriptionLimits, LimitError>]) { self.results = results }
    func currentLimits() async throws -> SubscriptionLimits {
        defer { index = Swift.min(index + 1, results.count - 1) }
        return try results[index].get()
    }
}

/// Like ``SequenceLimitProvider`` but counts calls, so throttle tests can assert a fetch was
/// (or wasn't) actually made. Accessed only from the `@MainActor` tests.
private final class CountingLimitProvider: LimitProvider, @unchecked Sendable {
    private let results: [Result<SubscriptionLimits, LimitError>]
    private(set) var calls = 0
    init(_ results: [Result<SubscriptionLimits, LimitError>]) { self.results = results }
    func currentLimits() async throws -> SubscriptionLimits {
        defer { calls += 1 }
        return try results[Swift.min(calls, results.count - 1)].get()
    }
}

/// A hand-cranked clock so tests can advance wall-clock time and exercise the backoff window
/// without sleeping.
private final class MutableClock {
    var now: Date
    init(_ start: Date = Date(timeIntervalSince1970: 0)) { self.now = start }
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

    func testLoadReturnsOutcome() async {
        // Bind each awaited outcome to a local first: `await` can't appear inside XCTAssertEqual's
        // autoclosure argument.
        let success = await consented(.success(limits())).load()
        XCTAssertEqual(success, .success)

        let limited = await consented(.failure(.rateLimited(retryAfter: 90))).load()
        XCTAssertEqual(limited, .rateLimited(retryAfter: 90))

        let transient = await consented(.failure(.requestFailed("boom"))).load()
        XCTAssertEqual(transient, .transientFailure)

        let terminal = await consented(.failure(.notSignedIn)).load()
        XCTAssertEqual(terminal, .terminal)
    }

    func testRateLimitedWithoutPriorDataStaysOnSpinner() async {
        // A 429 before we've ever loaded shows the spinner (still trying), not a hard error — this
        // is what kept the Codex gauge readable instead of flashing an error on a cold rate limit.
        let viewModel = consented(.failure(.rateLimited(retryAfter: nil)))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loading)
    }

    func testIsRateLimitedReflectsServer429ThenClearsOnSuccess() async {
        let clock = MutableClock()
        let viewModel = LimitViewModel(
            provider: SequenceLimitProvider([
                .failure(.rateLimited(retryAfter: 60)),
                .success(limits()),
            ]),
            consent: InMemoryConsentStore(true),
            pollInterval: 600,
            now: { clock.now })
        XCTAssertFalse(viewModel.isRateLimited)
        // A 429 turns the flag on so the UI can say "rate-limited — retrying" instead of looking frozen.
        await viewModel.load()
        XCTAssertTrue(viewModel.isRateLimited)
        // Step past the backoff window; the next clean fetch clears the flag.
        clock.now = clock.now.addingTimeInterval(3600)
        await viewModel.load()
        XCTAssertFalse(viewModel.isRateLimited)
    }

    func testKeepsLastGoodReadingThroughRateLimit() async {
        let clock = MutableClock()
        let viewModel = LimitViewModel(
            provider: SequenceLimitProvider([
                .success(limits()),
                .failure(.rateLimited(retryAfter: 60)),
            ]),
            consent: InMemoryConsentStore(true),
            pollInterval: 600,
            now: { clock.now })
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded(limits()))
        // Step past the poll window so the next load actually fetches (rather than throttling).
        clock.now = clock.now.addingTimeInterval(3600)
        // A 429 on the next poll must not wipe the gauge — it stays on the last good reading.
        let outcome = await viewModel.load()
        XCTAssertEqual(outcome, .rateLimited(retryAfter: 60))
        XCTAssertEqual(viewModel.state, .loaded(limits()))
    }

    func testKeepsLastGoodReadingThroughTransientFailure() async {
        let clock = MutableClock()
        let viewModel = LimitViewModel(
            provider: SequenceLimitProvider([
                .success(limits()),
                .failure(.requestFailed("network down")),
            ]),
            consent: InMemoryConsentStore(true),
            pollInterval: 600,
            now: { clock.now })
        await viewModel.load()
        clock.now = clock.now.addingTimeInterval(3600)
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded(limits()))
    }

    func testThrottleSkipsFetchInsideBackoffWindow() async {
        let clock = MutableClock()
        let provider = CountingLimitProvider([.success(limits())])
        let viewModel = LimitViewModel(
            provider: provider, consent: InMemoryConsentStore(true),
            pollInterval: 600, now: { clock.now })
        await viewModel.load()
        XCTAssertEqual(provider.calls, 1)
        // A menu-open inside the window must not fire another request — that was the 429 leak.
        await viewModel.load()
        XCTAssertEqual(provider.calls, 1)
        // Once the window elapses, the next load fetches again.
        clock.now = clock.now.addingTimeInterval(700)
        await viewModel.load()
        XCTAssertEqual(provider.calls, 2)
    }

    func testManualRefreshBypassesVoluntarySpacing() async {
        let clock = MutableClock()
        let provider = CountingLimitProvider([.success(limits()), .success(limits())])
        let viewModel = LimitViewModel(
            provider: provider, consent: InMemoryConsentStore(true),
            pollInterval: 600, now: { clock.now })
        await viewModel.load()
        XCTAssertEqual(provider.calls, 1)
        // Manual refresh may fetch early through our *voluntary* spacing (no rate limit in play).
        await viewModel.load(reason: .manual)
        XCTAssertEqual(provider.calls, 2)
    }

    func testManualRefreshHonorsRateLimitWithinCap() async {
        let clock = MutableClock()
        let provider = CountingLimitProvider([
            .failure(.rateLimited(retryAfter: 300)),
            .success(limits()),
        ])
        // Cap above the server's ask, so the manual button defers to the full Retry-After here.
        let viewModel = LimitViewModel(
            provider: provider, consent: InMemoryConsentStore(true),
            pollInterval: 600, manualRateLimitCap: 600, now: { clock.now })
        await viewModel.load()
        XCTAssertEqual(provider.calls, 1)
        // A manual refresh can't hammer us back into a 429 before Retry-After elapses.
        await viewModel.load(reason: .manual)
        XCTAssertEqual(provider.calls, 1)
        // Past the server's Retry-After, a manual refresh is allowed through.
        clock.now = clock.now.addingTimeInterval(400)
        await viewModel.load(reason: .manual)
        XCTAssertEqual(provider.calls, 2)
    }

    func testManualRefreshEscapesLongRateLimitAfterCap() async {
        let clock = MutableClock()
        let provider = CountingLimitProvider([
            .failure(.rateLimited(retryAfter: 600)),
            .success(limits()),
        ])
        // Server asks for a long 600s backoff; the manual button escapes after the 60s cap.
        let viewModel = LimitViewModel(
            provider: provider, consent: InMemoryConsentStore(true),
            pollInterval: 600, manualRateLimitCap: 60, now: { clock.now })
        await viewModel.load()  // trips the rate limit
        XCTAssertEqual(provider.calls, 1)
        // Within the cap, a manual refresh still defers.
        clock.now = clock.now.addingTimeInterval(30)
        await viewModel.load(reason: .manual)
        XCTAssertEqual(provider.calls, 1)
        // Now 70s in: past the cap, before Retry-After.
        clock.now = clock.now.addingTimeInterval(40)
        // The background poll still honors the *full* server Retry-After...
        await viewModel.load(reason: .scheduled)
        XCTAssertEqual(provider.calls, 1)
        // ...but the manual button is never a dead end — it's allowed through once the cap elapses.
        await viewModel.load(reason: .manual)
        XCTAssertEqual(provider.calls, 2)
    }

    func testPopupOpenRefreshesPastVoluntarySpacingButCoalescesReopens() async {
        let clock = MutableClock()
        let provider = CountingLimitProvider([.success(limits())])
        let viewModel = LimitViewModel(
            provider: provider, consent: InMemoryConsentStore(true),
            pollInterval: 600, popupMinInterval: 20, now: { clock.now })
        await viewModel.load(reason: .popupOpened)
        XCTAssertEqual(provider.calls, 1)
        // A rapid re-open inside the floor coalesces — no burst of requests.
        clock.now = clock.now.addingTimeInterval(10)
        await viewModel.load(reason: .popupOpened)
        XCTAssertEqual(provider.calls, 1)
        clock.now = clock.now.addingTimeInterval(15)  // now 25s: past the 20s floor
        // The background poll is still inside its 600s voluntary window, so it wouldn't fetch...
        await viewModel.load(reason: .scheduled)
        XCTAssertEqual(provider.calls, 1)
        // ...but a popup-open bypasses that voluntary spacing to show a near-live number.
        await viewModel.load(reason: .popupOpened)
        XCTAssertEqual(provider.calls, 2)
    }

    func testPopupOpenHonorsRealRateLimit() async {
        let clock = MutableClock()
        let provider = CountingLimitProvider([
            .failure(.rateLimited(retryAfter: 300)),
            .success(limits()),
        ])
        let viewModel = LimitViewModel(
            provider: provider, consent: InMemoryConsentStore(true),
            pollInterval: 600, popupMinInterval: 20, now: { clock.now })
        await viewModel.load(reason: .popupOpened)  // trips the rate limit
        XCTAssertEqual(provider.calls, 1)
        // Past the popup floor but inside the 429 window: a popup-open must not hammer the limit.
        clock.now = clock.now.addingTimeInterval(25)
        await viewModel.load(reason: .popupOpened)
        XCTAssertEqual(provider.calls, 1)
        // Once the server's Retry-After elapses, a popup-open fetches again. Step well past the
        // 300s ask so the backoff's one-sided jitter (up to +10%) can't leave us still blocked.
        clock.now = clock.now.addingTimeInterval(400)
        await viewModel.load(reason: .popupOpened)
        XCTAssertEqual(provider.calls, 2)
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
