import XCTest

@testable import DashiCore

final class ModelPricingTests: XCTestCase {
    // A fixed "now"; timestamps are derived from it so "same local day" never straddles a boundary.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let calendar = Calendar.current

    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private var today: String { iso.string(from: now) }

    private func aggregate(_ lines: String...) -> ProviderDailyTokens {
        var seen = Set<String>()
        return ClaudeDailyTokenSource.aggregate(
            lines: lines.map { Substring($0) }, now: now, calendar: calendar, seen: &seen)
    }

    // MARK: - Rate table

    func testCacheRatesDeriveFromInputRate() {
        let opus = ModelPricing.rates(forModel: "claude-opus-4-8")
        XCTAssertEqual(opus?.inputPerMTok, 5)
        XCTAssertEqual(opus?.outputPerMTok, 25)
        XCTAssertEqual(opus?.cacheWrite5mPerMTok ?? 0, 6.25, accuracy: 1e-9)
        XCTAssertEqual(opus?.cacheWrite1hPerMTok ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(opus?.cacheReadPerMTok ?? 0, 0.5, accuracy: 1e-9)
    }

    func testUnknownModelHasNoRates() {
        XCTAssertNil(ModelPricing.rates(forModel: "gpt-5.5"))
        XCTAssertNil(ModelPricing.rates(forModel: "claude-opus-4-5"))
        XCTAssertNil(ModelPricing.rates(forModel: ""))
    }

    func testSyntheticModelIsFree() {
        // Locally-generated turns never hit the API, so they price at zero rather than "unknown".
        let rates = ModelPricing.rates(forModel: ModelPricing.syntheticModel)
        XCTAssertNotNil(rates)
        XCTAssertEqual(rates?.cost(of: PricedTokens(input: 1_000_000, output: 1_000_000)), 0)
    }

    func testDatedSnapshotIDsResolveToTheirAlias() {
        XCTAssertEqual(ModelPricing.undatedModelID("claude-haiku-4-5-20251001"), "claude-haiku-4-5")
        XCTAssertEqual(ModelPricing.rates(forModel: "claude-haiku-4-5-20251001")?.inputPerMTok, 1)
        // Not a date suffix — must be left alone rather than truncated.
        XCTAssertEqual(ModelPricing.undatedModelID("claude-opus-4-8"), "claude-opus-4-8")
        XCTAssertEqual(ModelPricing.undatedModelID("short"), "short")
    }

    // MARK: - Cost arithmetic

    func testCostSumsEveryTokenCategoryAtItsOwnRate() {
        // Opus 4.8: input $5, output $25, cache read $0.50, 5m write $6.25, 1h write $10 per MTok.
        let cost = ModelRates(inputPerMTok: 5, outputPerMTok: 25).cost(
            of: PricedTokens(
                input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000))
        XCTAssertEqual(cost, 5 + 25 + 0.5 + 6.25 + 10, accuracy: 1e-9)
    }

    func testFormatUSD() {
        XCTAssertEqual(formatUSD(0), "$0.00")
        XCTAssertEqual(formatUSD(4.128), "$4.13")
        XCTAssertEqual(formatUSD(137.4), "$137.40")
        // Exact binary halves round to even, so 4.125 lands on $4.12 rather than $4.13. Fine for an
        // at-a-glance estimate — recorded here so the behavior is deliberate rather than a surprise.
        XCTAssertEqual(formatUSD(4.125), "$4.12")
        // Sub-cent usage rounds down to zero rather than growing a third decimal.
        XCTAssertEqual(formatUSD(0.0004), "$0.00")
    }

    // MARK: - Aggregation

    /// Pins the exact on-disk shape Claude Code writes, including the nested `cache_creation`
    /// object. Guards the assumption that `convertFromSnakeCase` maps `ephemeral_5m_input_tokens`
    /// onto `ephemeral5mInputTokens` — if that ever stops holding, the 1h/5m split silently
    /// mis-prices and this test is what catches it.
    func testPricesRealWorldTranscriptLineWithSplitCacheTiers() {
        let total = aggregate(
            """
            {"type":"assistant","timestamp":"\(today)","requestId":"r1","message":{"id":"m1",\
            "model":"claude-opus-4-8","usage":{"input_tokens":2,"cache_creation_input_tokens":8094,\
            "cache_read_input_tokens":13438,"output_tokens":322,"service_tier":"standard",\
            "cache_creation":{"ephemeral_1h_input_tokens":8094,"ephemeral_5m_input_tokens":0}}}}
            """)

        // 2 input @ $5 + 322 output @ $25 + 13438 read @ $0.50 + 8094 1h-write @ $10, per MTok.
        let expected =
            (2 * 5.0 + 322 * 25.0 + 13438 * 0.5 + 8094 * 10.0) / 1_000_000
        XCTAssertEqual(total.costUSD, expected, accuracy: 1e-9)
        XCTAssertEqual(total.unpricedTokens, 0)
        XCTAssertTrue(total.isFullyPriced)
        // The token total is unaffected by pricing.
        XCTAssertEqual(total.total, 2 + 322 + 13438 + 8094)
    }

    func testFlatCacheCreationBillsAtTheCheaperFiveMinuteRate() {
        // Older transcripts omit `cache_creation`; the whole write bills at 5m so an unknown split
        // can't overstate the cost.
        let total = aggregate(
            """
            {"type":"assistant","timestamp":"\(today)","requestId":"r1","message":{"id":"m1",\
            "model":"claude-opus-4-8","usage":{"input_tokens":0,"output_tokens":0,\
            "cache_creation_input_tokens":1000000,"cache_read_input_tokens":0}}}
            """)
        XCTAssertEqual(total.costUSD, 6.25, accuracy: 1e-9)
        XCTAssertEqual(total.cacheCreationTokens, 1_000_000)
        XCTAssertTrue(total.isFullyPriced)
    }

    func testUnknownModelCountsTokensButNotCost() {
        let total = aggregate(
            """
            {"type":"assistant","timestamp":"\(today)","requestId":"r1","message":{"id":"m1",\
            "model":"claude-from-the-future","usage":{"input_tokens":100,"output_tokens":20}}}
            """)
        XCTAssertEqual(total.total, 120)
        XCTAssertEqual(total.costUSD, 0)
        XCTAssertEqual(total.unpricedTokens, 120)
        XCTAssertFalse(total.isFullyPriced)
    }

    func testMixedModelsSumCostAndCarryUnpricedForward() {
        let total = aggregate(
            """
            {"type":"assistant","timestamp":"\(today)","requestId":"r1","message":{"id":"m1",\
            "model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":0}}}
            """,
            """
            {"type":"assistant","timestamp":"\(today)","requestId":"r2","message":{"id":"m2",\
            "model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0}}}
            """,
            """
            {"type":"assistant","timestamp":"\(today)","requestId":"r3","message":{"id":"m3",\
            "model":"mystery-model","usage":{"input_tokens":7,"output_tokens":3}}}
            """)
        XCTAssertEqual(total.costUSD, 3 + 5, accuracy: 1e-9)  // Sonnet 5 $3 + Opus 4.8 $5
        XCTAssertEqual(total.unpricedTokens, 10)
        XCTAssertFalse(total.isFullyPriced)
    }

    func testCodexUsageIsAlwaysUnpriced() {
        // Codex `token_count` events don't name a model, so nothing there can be priced — the
        // result must be "unknown", never a $0.00 that reads like "free".
        var seen = Set<String>()
        let total = CodexDailyTokenSource.aggregate(
            lines: [
                Substring(
                    """
                    {"timestamp":"\(today)","payload":{"type":"token_count","info":\
                    {"last_token_usage":{"input_tokens":13090,"cached_input_tokens":10112,\
                    "output_tokens":385}}}}
                    """)
            ], now: now, calendar: calendar, seen: &seen)
        XCTAssertEqual(total.costUSD, 0)
        XCTAssertEqual(total.unpricedTokens, total.total)
        XCTAssertFalse(total.isFullyPriced)
    }

    // MARK: - Accumulation

    func testAdditionSumsCostAndUnpricedTokens() {
        let a = ProviderDailyTokens(inputTokens: 10, costUSD: 1.5, unpricedTokens: 4)
        let b = ProviderDailyTokens(inputTokens: 5, costUSD: 2.25, unpricedTokens: 0)
        let sum = a + b
        XCTAssertEqual(sum.inputTokens, 15)
        XCTAssertEqual(sum.costUSD, 3.75, accuracy: 1e-9)
        XCTAssertEqual(sum.unpricedTokens, 4)
    }

    func testZeroIsFullyPriced() {
        XCTAssertTrue(ProviderDailyTokens.zero.isFullyPriced)
        XCTAssertEqual(ProviderDailyTokens.zero.costUSD, 0)
    }
}
