import XCTest

@testable import DashiCore

@MainActor
final class UsageViewModelTests: XCTestCase {
    func testLoadedStateOnSuccess() async {
        let summary = UsageSummary.fixture()
        let viewModel = UsageViewModel(provider: StubUsageProvider(result: .success(summary)))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded(summary))
    }

    func testEmptyStateWhenNoProviders() async {
        let viewModel = UsageViewModel(
            provider: StubUsageProvider(result: .success(.fixture([]))))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .empty)
    }

    func testNotConnectedBecomesConnectPrompt() async {
        let viewModel = UsageViewModel(
            provider: StubUsageProvider(result: .failure(.notConnected(.anthropic))))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .failed("Connect your Anthropic account"))
    }

    func testRequestFailedSurfacesMessage() async {
        let viewModel = UsageViewModel(
            provider: StubUsageProvider(result: .failure(.requestFailed("boom"))))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .failed("boom"))
    }
}
