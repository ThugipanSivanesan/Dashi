import XCTest

@testable import DashiCore

final class ProviderFactoryTests: XCTestCase {
    func testOfflineModeReturnsOfflineProvider() {
        let provider = makeUsageProvider(Settings(providerMode: .offline))
        XCTAssertTrue(provider is OfflineUsageProvider)
    }

    func testAnthropicModeReturnsAnthropicProvider() {
        let provider = makeUsageProvider(
            Settings(providerMode: .anthropic), store: InMemorySecretStore())
        XCTAssertTrue(provider is AnthropicUsageProvider)
    }

    func testOpenAIModeReturnsOpenAIProvider() {
        let provider = makeUsageProvider(
            Settings(providerMode: .openai), store: InMemorySecretStore())
        XCTAssertTrue(provider is OpenAIUsageProvider)
    }

    func testAggregateModeReturnsAggregateProvider() {
        let provider = makeUsageProvider(
            Settings(providerMode: .aggregate), store: InMemorySecretStore())
        XCTAssertTrue(provider is AggregateUsageProvider)
    }
}
