import Foundation

/// The outcome of one usage-poll attempt, from the scheduler's point of view. Drives how long to
/// wait before the next poll (see ``PollBackoff``).
public enum PollOutcome: Sendable, Equatable {
    /// Fresh limits were fetched. Poll again at the normal cadence.
    case success
    /// The server asked us to slow down (HTTP 429). `retryAfter` is its `Retry-After` value in
    /// seconds when the header was present and parseable.
    case rateLimited(retryAfter: TimeInterval?)
    /// A transient failure (network error, 5xx, decode error). Back off exponentially and retry.
    case transientFailure
    /// A terminal state (not signed in, needs re-auth, needs consent). These don't rate-limit us,
    /// so keep the normal cadence — we want to notice promptly when the state clears.
    case terminal
}

/// Decides how long to wait before the next usage poll. In priority order it applies the server's
/// `Retry-After` on 429, exponential backoff for repeated 429s / transient failures (bounded by
/// `maxInterval`), and the normal cadence otherwise — then adds a little one-sided jitter so
/// multiple pollers (or app instances) don't fire in lockstep.
///
/// Pure and value-typed so the polling policy is unit-testable without SwiftUI or a real clock.
public struct PollBackoff: Sendable {
    /// The normal cadence between successful polls.
    public let baseInterval: TimeInterval
    /// Floor for any computed delay. Also floors a tiny — or bogus — server `Retry-After`: the usage
    /// endpoint has been observed returning `429` with `retry-after: 0` (retry immediately, yet still
    /// rate-limited), which without a floor would spin us straight back into the limit.
    public let minInterval: TimeInterval
    /// Cap for our *own* exponential backoff. A server-directed `Retry-After` may exceed it —
    /// we always honor the server's ask so we don't poll back into the same limit.
    public let maxInterval: TimeInterval
    /// Fraction of the delay added as random jitter (e.g. 0.1 = up to +10%).
    public let jitterFraction: Double

    private var consecutiveFailures = 0

    public init(
        baseInterval: TimeInterval,
        minInterval: TimeInterval = 90,
        maxInterval: TimeInterval = 1800,
        jitterFraction: Double = 0.1
    ) {
        self.baseInterval = max(1, baseInterval)
        self.minInterval = max(1, minInterval)
        self.maxInterval = max(max(1, minInterval), maxInterval)
        self.jitterFraction = min(1, max(0, jitterFraction))
    }

    /// Records `outcome` and returns the delay (seconds) to wait before the next poll.
    /// `randomUnit` supplies jitter in `0...1`; it's injectable so tests stay deterministic.
    public mutating func nextDelay(
        after outcome: PollOutcome,
        randomUnit: () -> Double = { Double.random(in: 0...1) }
    ) -> TimeInterval {
        let base: TimeInterval
        switch outcome {
        case .success, .terminal:
            consecutiveFailures = 0
            base = baseInterval
        case .rateLimited(let retryAfter):
            consecutiveFailures += 1
            // Trust the server's ask (floored by min, never capped); otherwise back off ourselves.
            base = retryAfter.map { max(minInterval, $0) } ?? clamped(exponentialBackoff())
        case .transientFailure:
            consecutiveFailures += 1
            base = clamped(exponentialBackoff())
        }
        return jittered(base, randomUnit: randomUnit)
    }

    /// `base * 2^(failures-1)`, so the first failure waits one interval and each further failure
    /// doubles it. The exponent is capped to avoid overflow before `clamped` bounds the result.
    private func exponentialBackoff() -> TimeInterval {
        let exponent = min(max(0, consecutiveFailures - 1), 16)
        return baseInterval * pow(2.0, Double(exponent))
    }

    private func clamped(_ value: TimeInterval) -> TimeInterval {
        min(maxInterval, max(minInterval, value))
    }

    /// One-sided positive jitter: `value ... value + jitterFraction*value`. Never returns less
    /// than `value`, so we can't accidentally poll *before* a server-directed `Retry-After`.
    private func jittered(_ value: TimeInterval, randomUnit: () -> Double) -> TimeInterval {
        guard jitterFraction > 0 else { return value }
        let unit = min(1, max(0, randomUnit()))
        return value + value * jitterFraction * unit
    }
}

/// Parses an HTTP `Retry-After` header into a delay in seconds. Handles the delta-seconds form
/// (what the usage endpoints return on 429) and, defensively, the HTTP-date form. Returns `nil`
/// when the header is absent or unparseable so the caller can fall back to its own backoff.
func parseRetryAfter(_ response: HTTPURLResponse, now: Date) -> TimeInterval? {
    guard
        let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces),
        !raw.isEmpty
    else { return nil }

    if let seconds = TimeInterval(raw) { return max(0, seconds) }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let date = formatter.date(from: raw) { return max(0, date.timeIntervalSince(now)) }
    return nil
}
