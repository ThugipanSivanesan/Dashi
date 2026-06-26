import XCTest

@testable import DashiCore

final class UsageModelsTests: XCTestCase {
    func testProviderUsageTotalTokens() {
        let usage = ProviderUsage(
            provider: .anthropic, inputTokens: 100, outputTokens: 25, estimatedCostUSD: 1.0)
        XCTAssertEqual(usage.totalTokens, 125)
    }

    func testSummaryTotalsSumAcrossProviders() {
        let summary = UsageSummary(
            date: Date(timeIntervalSince1970: 0),
            providers: [
                ProviderUsage(
                    provider: .anthropic, inputTokens: 100, outputTokens: 20, estimatedCostUSD: 0.5),
                ProviderUsage(
                    provider: .openai, inputTokens: 50, outputTokens: 10, estimatedCostUSD: 0.25),
            ]
        )
        XCTAssertEqual(summary.totalInputTokens, 150)
        XCTAssertEqual(summary.totalOutputTokens, 30)
        XCTAssertEqual(summary.totalTokens, 180)
        XCTAssertEqual(summary.totalCostUSD, 0.75, accuracy: 0.0001)
    }

    func testEmptySummaryTotalsAreZero() {
        let summary = UsageSummary(date: Date(timeIntervalSince1970: 0), providers: [])
        XCTAssertEqual(summary.totalTokens, 0)
        XCTAssertEqual(summary.totalCostUSD, 0)
    }
}
