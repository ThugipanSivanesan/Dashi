import Foundation

/// Builds the usage provider for the configured mode. `.offline` is the default and requires no
/// credentials; live modes read keys from `store` (the Keychain in production) at the point of use.
public func makeUsageProvider(
    _ settings: Settings,
    store: any SecretStore = KeychainStore()
) -> any UsageProvider {
    switch settings.providerMode {
    case .offline:
        return OfflineUsageProvider()
    case .anthropic:
        return AnthropicUsageProvider(store: store)
    case .openai:
        return OpenAIUsageProvider(store: store)
    case .aggregate:
        return AggregateUsageProvider(providers: [
            AnthropicUsageProvider(store: store),
            OpenAIUsageProvider(store: store),
        ])
    }
}
