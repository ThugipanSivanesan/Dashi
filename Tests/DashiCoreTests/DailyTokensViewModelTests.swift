import XCTest

@testable import DashiCore

/// Source with a canned answer; `nil` stands for logs that were absent or unreadable.
private struct StubDailyTokenSource: DailyTokenSource {
    let tokens: ProviderDailyTokens?
    func tokensToday() -> ProviderDailyTokens? { tokens }
}

@MainActor
final class DailyTokensViewModelTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func viewModel(claude: ProviderDailyTokens?, codex: ProviderDailyTokens?)
        -> DailyTokensViewModel
    {
        let stamp = fetchedAt
        return DailyTokensViewModel(
            claudeSource: StubDailyTokenSource(tokens: claude),
            codexSource: StubDailyTokenSource(tokens: codex),
            now: { stamp })
    }

    /// Pins what `load()` publishes: each source's own total on its own field, stamped with the
    /// injected clock. `DailyTokens` is `Equatable`, so one comparison is the whole snapshot.
    func testLoadPublishesBothProvidersAndStampsFetchedAt() async {
        let claude = ProviderDailyTokens(inputTokens: 100, outputTokens: 20, unpricedTokens: 120)
        let codex = ProviderDailyTokens(inputTokens: 7, outputTokens: 3, unpricedTokens: 10)
        let model = viewModel(claude: claude, codex: codex)
        XCTAssertNil(model.tokens, "no snapshot until the first load completes")

        await model.load()

        XCTAssertEqual(
            model.tokens, DailyTokens(claude: claude, codex: codex, fetchedAt: fetchedAt))
    }

    /// An unavailable source reaches the snapshot as `nil` on its own field, never flattened to
    /// `.zero`, keeping the distinction ``DailyTokens`` documents. Both sides are checked because
    /// either field could lose it alone.
    func testLoadKeepsAnUnavailableSourceNil() async {
        let used = ProviderDailyTokens(inputTokens: 40, outputTokens: 10, unpricedTokens: 50)
        let cases: [(claude: ProviderDailyTokens?, codex: ProviderDailyTokens?)] = [
            (claude: nil, codex: used), (claude: used, codex: nil),
        ]
        for expected in cases {
            let model = viewModel(claude: expected.claude, codex: expected.codex)
            await model.load()
            XCTAssertEqual(
                model.tokens,
                DailyTokens(
                    claude: expected.claude, codex: expected.codex, fetchedAt: fetchedAt),
                "claude: \(String(describing: expected.claude))")
        }
    }
}
