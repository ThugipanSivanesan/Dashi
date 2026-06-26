import Foundation

/// A usage provider Dashi can read from.
public enum Provider: String, Sendable, CaseIterable, Codable {
    case anthropic
    case openai

    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        }
    }
}

/// One provider's token usage and estimated cost for a day.
public struct ProviderUsage: Sendable, Equatable, Identifiable {
    public let provider: Provider
    public let inputTokens: Int
    public let outputTokens: Int
    public let estimatedCostUSD: Double

    public var id: Provider { provider }
    public var totalTokens: Int { inputTokens + outputTokens }

    public init(provider: Provider, inputTokens: Int, outputTokens: Int, estimatedCostUSD: Double) {
        self.provider = provider
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.estimatedCostUSD = estimatedCostUSD
    }
}

/// A day's usage across one or more providers. Totals are derived deterministically from
/// `providers` so the UI never has to recompute or risk drift.
public struct UsageSummary: Sendable, Equatable {
    public let date: Date
    public let providers: [ProviderUsage]

    public init(date: Date, providers: [ProviderUsage]) {
        self.date = date
        self.providers = providers
    }

    public var totalInputTokens: Int { providers.reduce(0) { $0 + $1.inputTokens } }
    public var totalOutputTokens: Int { providers.reduce(0) { $0 + $1.outputTokens } }
    public var totalTokens: Int { totalInputTokens + totalOutputTokens }
    public var totalCostUSD: Double { providers.reduce(0) { $0 + $1.estimatedCostUSD } }
}
