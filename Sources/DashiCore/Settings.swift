import Foundation

/// Which usage source the app reads from. Defaults to `.offline` so the app — and the whole
/// test suite — runs with no network, no credentials, and no spend.
public enum ProviderMode: String, Sendable, CaseIterable {
    case offline
    case anthropic
    case openai
    case aggregate
}

/// Non-secret application configuration, validated at startup. Secrets never live here — API
/// keys are read from the Keychain at the point of use (see ``KeychainStore``).
public struct Settings: Sendable, Equatable {
    public var providerMode: ProviderMode
    /// Seconds between usage polls. Kept short enough that the gauge feels live, while the scheduler
    /// adds jitter and backs off automatically on 429s (honoring the server's `Retry-After`, see
    /// ``PollBackoff``) so a brisk cadence can't hammer the endpoint. Override with `DASHI_POLL_INTERVAL`.
    public var pollInterval: TimeInterval

    public init(providerMode: ProviderMode = .offline, pollInterval: TimeInterval = 90) {
        self.providerMode = providerMode
        self.pollInterval = max(1, pollInterval)
    }

    /// Builds settings from environment variables, ignoring malformed values (fail-safe to
    /// defaults rather than crashing on bad config).
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Settings {
        var settings = Settings()
        if let raw = env["DASHI_PROVIDER_MODE"],
            let mode = ProviderMode(rawValue: raw.lowercased())
        {
            settings.providerMode = mode
        }
        if let raw = env["DASHI_POLL_INTERVAL"], let value = TimeInterval(raw), value > 0 {
            settings.pollInterval = value
        }
        return settings
    }
}
