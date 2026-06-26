import Foundation

@testable import DashiCore

/// Test double that returns a fixed summary or throws a fixed error.
struct StubUsageProvider: UsageProvider {
    var result: Result<UsageSummary, UsageError>

    func todayUsage() async throws -> UsageSummary {
        try result.get()
    }
}

extension UsageSummary {
    static func fixture(
        _ providers: [ProviderUsage] = [
            ProviderUsage(
                provider: .anthropic, inputTokens: 10, outputTokens: 2, estimatedCostUSD: 0.1)
        ]
    ) -> UsageSummary {
        UsageSummary(date: Date(timeIntervalSince1970: 0), providers: providers)
    }
}
