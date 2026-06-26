import Foundation

/// Default provider: returns deterministic canned usage with no network or credentials. Keeps the
/// app demoable and the test suite hermetic.
public struct OfflineUsageProvider: UsageProvider {
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func todayUsage() async throws -> UsageSummary {
        UsageSummary(
            date: now(),
            providers: [
                ProviderUsage(
                    provider: .anthropic,
                    inputTokens: 12_500,
                    outputTokens: 3_200,
                    estimatedCostUSD: 0.42
                ),
                ProviderUsage(
                    provider: .openai,
                    inputTokens: 8_100,
                    outputTokens: 1_900,
                    estimatedCostUSD: 0.18
                ),
            ]
        )
    }
}
