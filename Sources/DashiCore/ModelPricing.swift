import Foundation

/// Published pay-as-you-go API rates for one model, in USD per million tokens.
///
/// Only the two base rates are stored: Anthropic prices cache traffic as fixed multiples of the
/// input rate, so deriving them keeps the table short and impossible to get internally inconsistent.
public struct ModelRates: Sendable, Equatable {
    public let inputPerMTok: Double
    public let outputPerMTok: Double

    public init(inputPerMTok: Double, outputPerMTok: Double) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
    }

    /// Writing to the 5-minute cache costs 1.25x the base input rate.
    public var cacheWrite5mPerMTok: Double { inputPerMTok * 1.25 }
    /// Writing to the 1-hour cache costs 2x the base input rate.
    public var cacheWrite1hPerMTok: Double { inputPerMTok * 2 }
    /// Reading from either cache costs 0.1x the base input rate.
    public var cacheReadPerMTok: Double { inputPerMTok * 0.1 }

    /// What this usage would have cost at these rates.
    public func cost(of tokens: PricedTokens) -> Double {
        let perToken =
            Double(tokens.input) * inputPerMTok
            + Double(tokens.output) * outputPerMTok
            + Double(tokens.cacheRead) * cacheReadPerMTok
            + Double(tokens.cacheWrite5m) * cacheWrite5mPerMTok
            + Double(tokens.cacheWrite1h) * cacheWrite1hPerMTok
        return perToken / 1_000_000
    }
}

/// One turn's token counts, split the way pricing treats them. Distinct from ``ProviderDailyTokens``
/// because the two cache-write tiers bill differently and only matter here.
public struct PricedTokens: Sendable, Equatable {
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheWrite5m: Int
    public let cacheWrite1h: Int

    public init(
        input: Int = 0, output: Int = 0, cacheRead: Int = 0,
        cacheWrite5m: Int = 0, cacheWrite1h: Int = 0
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    public var total: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }
}

/// Maps a model id to its published rates.
///
/// Deliberately incomplete: a model absent from the table is reported as *unpriced* rather than
/// guessed at, so the UI can say "we don't know" instead of showing a fabricated dollar figure.
/// Codex/OpenAI models are all unpriced today — their published rates aren't wired in yet.
public enum ModelPricing {
    /// Rates as published by Anthropic, keyed by the id Claude Code writes to `message.model`.
    ///
    /// Sonnet 5 carries a reduced introductory rate through 2026-08-31; we bill it at list price so
    /// the estimate doesn't silently become wrong the day the promotion ends.
    private static let anthropic: [String: ModelRates] = [
        "claude-fable-5": ModelRates(inputPerMTok: 10, outputPerMTok: 50),
        "claude-mythos-5": ModelRates(inputPerMTok: 10, outputPerMTok: 50),
        "claude-opus-4-8": ModelRates(inputPerMTok: 5, outputPerMTok: 25),
        "claude-opus-4-7": ModelRates(inputPerMTok: 5, outputPerMTok: 25),
        "claude-opus-4-6": ModelRates(inputPerMTok: 5, outputPerMTok: 25),
        "claude-sonnet-5": ModelRates(inputPerMTok: 3, outputPerMTok: 15),
        "claude-sonnet-4-6": ModelRates(inputPerMTok: 3, outputPerMTok: 15),
        "claude-haiku-4-5": ModelRates(inputPerMTok: 1, outputPerMTok: 5),
    ]

    /// Claude Code labels locally-generated turns `<synthetic>`. They never hit the API, so they
    /// cost nothing — priced at zero rather than counted as "unknown model".
    public static let syntheticModel = "<synthetic>"

    /// The rates for `model`, or `nil` if we have no published figure for it.
    ///
    /// Ids may carry a dated-snapshot suffix (`claude-sonnet-4-5-20250929`); the alias is tried
    /// first, then the id with a trailing `-YYYYMMDD` stripped.
    public static func rates(forModel model: String) -> ModelRates? {
        if model == syntheticModel { return ModelRates(inputPerMTok: 0, outputPerMTok: 0) }
        if let exact = anthropic[model] { return exact }
        return anthropic[undatedModelID(model)]
    }

    /// Drops a trailing `-YYYYMMDD` snapshot suffix, leaving the alias.
    static func undatedModelID(_ model: String) -> String {
        guard model.count > 9 else { return model }
        let suffix = model.suffix(9)
        guard suffix.first == "-", suffix.dropFirst().allSatisfy(\.isNumber) else { return model }
        return String(model.dropLast(9))
    }
}

/// Formats a USD amount for the menu, e.g. `$0.00`, `$4.12`, `$137.40`.
///
/// Sub-cent amounts round to `$0.00` rather than growing a third decimal — the readout is an
/// at-a-glance estimate, not an invoice.
public func formatUSD(_ amount: Double) -> String {
    String(format: "$%.2f", amount)
}
