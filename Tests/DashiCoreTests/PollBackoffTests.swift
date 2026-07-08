import XCTest

@testable import DashiCore

final class PollBackoffTests: XCTestCase {
    /// No jitter keeps the arithmetic exact; individual tests opt back in where they check jitter.
    private func backoff(
        base: TimeInterval = 600, min: TimeInterval = 30, max: TimeInterval = 1800,
        jitter: Double = 0
    ) -> PollBackoff {
        PollBackoff(baseInterval: base, minInterval: min, maxInterval: max, jitterFraction: jitter)
    }

    func testSuccessUsesBaseInterval() {
        var b = backoff()
        XCTAssertEqual(b.nextDelay(after: .success), 600)
    }

    func testTerminalUsesBaseInterval() {
        var b = backoff()
        XCTAssertEqual(b.nextDelay(after: .terminal), 600)
    }

    func testRateLimitedHonorsRetryAfter() {
        var b = backoff()
        XCTAssertEqual(b.nextDelay(after: .rateLimited(retryAfter: 120)), 120)
    }

    func testRetryAfterIsFlooredByMinButNotCappedByMax() {
        var b = backoff(min: 30, max: 1800)
        // Below the floor is raised to min...
        XCTAssertEqual(b.nextDelay(after: .rateLimited(retryAfter: 5)), 30)
        // ...but a long server ask is respected even past maxInterval, so we don't poll early.
        XCTAssertEqual(b.nextDelay(after: .rateLimited(retryAfter: 3600)), 3600)
    }

    func testRateLimitedWithoutRetryAfterBacksOffExponentially() {
        var b = backoff(base: 600, max: 5000)
        XCTAssertEqual(b.nextDelay(after: .rateLimited(retryAfter: nil)), 600)  // 600 * 2^0
        XCTAssertEqual(b.nextDelay(after: .rateLimited(retryAfter: nil)), 1200)  // 600 * 2^1
        XCTAssertEqual(b.nextDelay(after: .rateLimited(retryAfter: nil)), 2400)  // 600 * 2^2
    }

    func testTransientFailureBacksOffExponentiallyAndCaps() {
        var b = backoff(base: 600, max: 1800)
        XCTAssertEqual(b.nextDelay(after: .transientFailure), 600)
        XCTAssertEqual(b.nextDelay(after: .transientFailure), 1200)
        XCTAssertEqual(b.nextDelay(after: .transientFailure), 1800)  // capped (2400 -> 1800)
        XCTAssertEqual(b.nextDelay(after: .transientFailure), 1800)  // stays capped
    }

    func testSuccessResetsBackoff() {
        var b = backoff(base: 600, max: 5000)
        _ = b.nextDelay(after: .transientFailure)  // 600
        _ = b.nextDelay(after: .transientFailure)  // 1200
        XCTAssertEqual(b.nextDelay(after: .success), 600)
        // Next failure starts from the base again, proving the counter reset.
        XCTAssertEqual(b.nextDelay(after: .transientFailure), 600)
    }

    func testJitterIsPositiveAndBounded() {
        var b = backoff(base: 1000, jitter: 0.1)
        XCTAssertEqual(b.nextDelay(after: .success, randomUnit: { 0 }), 1000)  // no jitter added
        XCTAssertEqual(b.nextDelay(after: .success, randomUnit: { 1 }), 1100)  // full +10%
        XCTAssertEqual(b.nextDelay(after: .success, randomUnit: { 0.5 }), 1050)  // half
    }

    func testJitterNeverPollsBeforeRetryAfter() {
        var b = backoff(base: 600, jitter: 0.25)
        // Even at the extreme jitter draw, the delay is >= the server's ask.
        XCTAssertGreaterThanOrEqual(
            b.nextDelay(after: .rateLimited(retryAfter: 200), randomUnit: { 0 }), 200)
    }

    func testInitClampsDegenerateBounds() {
        // maxInterval below minInterval is raised to minInterval; jitter clamped to 0...1.
        var b = PollBackoff(baseInterval: 100, minInterval: 90, maxInterval: 10, jitterFraction: 5)
        // base (100) clamps to [90, 90] -> 90, then full jitter (clamped to 1.0) adds +100%.
        XCTAssertEqual(b.nextDelay(after: .transientFailure, randomUnit: { 1 }), 180)
    }
}

final class RetryAfterParsingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func response(retryAfter: String?) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let retryAfter { headers["Retry-After"] = retryAfter }
        return HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            statusCode: 429, httpVersion: nil, headerFields: headers)!
    }

    func testParsesDeltaSeconds() {
        XCTAssertEqual(parseRetryAfter(response(retryAfter: "90"), now: now), 90)
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(parseRetryAfter(response(retryAfter: "  42  "), now: now), 42)
    }

    func testAbsentHeaderIsNil() {
        XCTAssertNil(parseRetryAfter(response(retryAfter: nil), now: now))
    }

    func testGarbageIsNil() {
        XCTAssertNil(parseRetryAfter(response(retryAfter: "soon"), now: now))
    }

    func testParsesHttpDateAsDeltaFromNow() {
        // now + 120s in the HTTP-date format.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let dateString = formatter.string(from: now.addingTimeInterval(120))
        let parsed = parseRetryAfter(response(retryAfter: dateString), now: now)
        XCTAssertEqual(try XCTUnwrap(parsed), 120, accuracy: 1.0)
    }
}
