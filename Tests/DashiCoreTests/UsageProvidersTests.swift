import XCTest

@testable import DashiCore

final class UsageProvidersTests: XCTestCase {
    func testOfflineProviderReturnsDeterministicData() async throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = try await OfflineUsageProvider(now: { fixed }).todayUsage()
        XCTAssertEqual(summary.date, fixed)
        XCTAssertEqual(Set(summary.providers.map(\.provider)), [.anthropic, .openai])
        XCTAssertGreaterThan(summary.totalTokens, 0)
    }

    func testLiveProviderFailsClosedWithoutKey() async {
        let provider = AnthropicUsageProvider(store: InMemorySecretStore())
        await assertThrows(provider) { error in
            XCTAssertEqual(error, .notConnected(.anthropic))
        }
    }

    func testLiveProviderWithKeyReachesFetch() async {
        let store = InMemorySecretStore(["openai": "sk-test-key"])  // gitleaks:allow
        let provider = OpenAIUsageProvider(store: store)
        await assertThrows(provider) { error in
            // Key present → past the fail-closed guard; fetch itself is not implemented yet.
            guard case .requestFailed = error else {
                return XCTFail("expected requestFailed, got \(error)")
            }
        }
    }

    func testAggregateSkipsUnconnectedProviders() async throws {
        let store = InMemorySecretStore()  // neither provider connected
        let connected = StubUsageProvider(
            result: .success(
                .fixture([
                    ProviderUsage(
                        provider: .openai, inputTokens: 5, outputTokens: 1, estimatedCostUSD: 0.05)
                ])))
        let aggregate = AggregateUsageProvider(providers: [
            AnthropicUsageProvider(store: store),  // throws notConnected → skipped
            connected,
        ])
        let summary = try await aggregate.todayUsage()
        XCTAssertEqual(summary.providers.map(\.provider), [.openai])
    }

    // MARK: - Helper

    private func assertThrows(
        _ provider: any UsageProvider,
        _ check: (UsageError) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await provider.todayUsage()
            XCTFail("expected throw", file: file, line: line)
        } catch let error as UsageError {
            check(error)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}
