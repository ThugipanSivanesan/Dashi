import Foundation

/// Non-secret application configuration, validated at startup. Secrets never live here — the
/// providers read the CLI's own OAuth token from disk at the point of use.
public struct Settings: Sendable, Equatable {
    /// Seconds between usage polls. The unofficial usage endpoint rate-limits per-account hard, so a
    /// gentle cadence keeps us well clear of its 429s — an over-eager poll ironically freezes the gauge
    /// *longer* (stuck on stale data during backoff) than a calm one. A popup-open still refreshes past
    /// this for a near-live number, and the scheduler adds jitter and honors the server's `Retry-After`
    /// (see ``PollBackoff``). Override with `DASHI_POLL_INTERVAL`.
    public var pollInterval: TimeInterval

    public init(pollInterval: TimeInterval = 300) {
        self.pollInterval = max(1, pollInterval)
    }

    /// Builds settings from environment variables, ignoring malformed values (fail-safe to
    /// defaults rather than crashing on bad config).
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Settings {
        var settings = Settings()
        if let raw = env["DASHI_POLL_INTERVAL"], let value = TimeInterval(raw), value > 0 {
            settings.pollInterval = value
        }
        return settings
    }
}
