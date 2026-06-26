import Foundation

/// Reads the provider's API key from the secret store at the point of use and fails closed when it
/// is absent. The network fetch itself is finalized in a follow-up slice — per-day usage requires
/// admin/org-scoped keys and the providers' usage/cost reporting endpoints (see README). The
/// URLSession call lives inside `todayUsage()` so the default offline path never builds a request.
private func requireKey(_ provider: Provider, from store: any SecretStore) throws -> Secret {
    guard let key = try store.get(provider.rawValue), !key.isEmpty else {
        throw UsageError.notConnected(provider)
    }
    return key
}

/// Live Anthropic usage via the Usage & Cost Admin API (admin-scoped key). Fetch not yet implemented.
public struct AnthropicUsageProvider: UsageProvider {
    private let store: any SecretStore

    public init(store: any SecretStore = KeychainStore()) {
        self.store = store
    }

    public func todayUsage() async throws -> UsageSummary {
        _ = try requireKey(.anthropic, from: store)
        throw UsageError.requestFailed("Anthropic live usage fetch is not implemented yet")
    }
}

/// Live OpenAI usage via the organization usage/costs endpoints (admin key). Fetch not yet implemented.
public struct OpenAIUsageProvider: UsageProvider {
    private let store: any SecretStore

    public init(store: any SecretStore = KeychainStore()) {
        self.store = store
    }

    public func todayUsage() async throws -> UsageSummary {
        _ = try requireKey(.openai, from: store)
        throw UsageError.requestFailed("OpenAI live usage fetch is not implemented yet")
    }
}

/// Combines several providers into one summary, skipping any that aren't connected so a partially
/// configured setup still shows the data it can.
public struct AggregateUsageProvider: UsageProvider {
    private let providers: [any UsageProvider]
    private let now: @Sendable () -> Date

    public init(providers: [any UsageProvider], now: @escaping @Sendable () -> Date = Date.init) {
        self.providers = providers
        self.now = now
    }

    public func todayUsage() async throws -> UsageSummary {
        var collected: [ProviderUsage] = []
        for provider in providers {
            do {
                let summary = try await provider.todayUsage()
                collected.append(contentsOf: summary.providers)
            } catch UsageError.notConnected {
                continue
            }
        }
        return UsageSummary(date: now(), providers: collected)
    }
}
