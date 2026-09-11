import XCTest

@testable import DashiCore

/// Returns a canned total, or nil for logs that were absent or unreadable.
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

    /// Publishes each source's total on its own field, stamped with the injected clock.
    func testLoadPublishesBothProvidersAndStampsFetchedAt() async {
        let claude = ProviderDailyTokens(inputTokens: 100, outputTokens: 20, unpricedTokens: 120)
        let codex = ProviderDailyTokens(inputTokens: 7, outputTokens: 3, unpricedTokens: 10)
        let model = viewModel(claude: claude, codex: codex)
        XCTAssertNil(model.tokens, "no snapshot until the first load completes")

        await model.load()

        XCTAssertEqual(
            model.tokens, DailyTokens(claude: claude, codex: codex, fetchedAt: fetchedAt))
    }

    /// Keeps an unavailable source as nil on the snapshot, checking each side in turn.
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
