import Foundation

/// Today's token usage for a single provider, broken down by category. Summed from the provider's
/// local CLI session logs (Claude Code transcripts / Codex session rollouts), not the usage
/// endpoints — those only report rolling-window *percentages*, never raw token counts.
public struct ProviderDailyTokens: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    /// What today's usage would have cost at pay-as-you-go API rates, summed over the turns whose
    /// model we have published rates for. Subscription usage isn't actually billed per token — this
    /// is the equivalent-cost estimate, not a charge.
    public let costUSD: Double
    /// Tokens from turns we couldn't price (unrecognized or unrecorded model). Non-zero means
    /// ``costUSD`` is a floor, not the whole picture.
    public let unpricedTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        costUSD: Double = 0,
        unpricedTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.costUSD = costUSD
        self.unpricedTokens = unpricedTokens
    }

    /// Total tokens the model processed today, across fresh input, output, and cache reads/writes —
    /// the headline "tokens used today" figure.
    public var total: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    /// Whether every token counted today came from a model we have rates for. False means the
    /// estimate understates the true equivalent cost.
    public var isFullyPriced: Bool { unpricedTokens == 0 }

    public static let zero = ProviderDailyTokens()

    public static func + (lhs: ProviderDailyTokens, rhs: ProviderDailyTokens) -> ProviderDailyTokens
    {
        ProviderDailyTokens(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            costUSD: lhs.costUSD + rhs.costUSD,
            unpricedTokens: lhs.unpricedTokens + rhs.unpricedTokens)
    }
}

/// A snapshot of today's per-provider token usage. A `nil` provider means its logs were absent or
/// unreadable (render as "—"); `.zero` means the logs were read but nothing was used today.
public struct DailyTokens: Sendable, Equatable {
    public let claude: ProviderDailyTokens?
    public let codex: ProviderDailyTokens?
    public let fetchedAt: Date

    public init(claude: ProviderDailyTokens?, codex: ProviderDailyTokens?, fetchedAt: Date) {
        self.claude = claude
        self.codex = codex
        self.fetchedAt = fetchedAt
    }
}

/// A source of one provider's token usage for the current local calendar day, read from its local
/// logs. Returns `nil` when the log location is missing/unreadable so the UI can distinguish
/// "unavailable" from "zero used today".
public protocol DailyTokenSource: Sendable {
    func tokensToday() -> ProviderDailyTokens?
}

/// Formats a token count compactly for the menu, e.g. `823`, `5.6K`, `340K`, `1.2M`, `3.4B`.
public func formatTokenCount(_ count: Int) -> String {
    let sign = count < 0 ? "-" : ""
    let value = abs(count)
    switch value {
    case ..<1_000:
        return "\(sign)\(value)"
    case ..<1_000_000:
        return sign + compactToken(Double(value) / 1_000, "K")
    case ..<1_000_000_000:
        return sign + compactToken(Double(value) / 1_000_000, "M")
    default:
        return sign + compactToken(Double(value) / 1_000_000_000, "B")
    }
}

/// Rounds to one decimal and drops a trailing `.0`, so `340.0 → "340K"` but `5.6 → "5.6K"`.
private func compactToken(_ scaled: Double, _ suffix: String) -> String {
    let rounded = (scaled * 10).rounded() / 10
    if rounded == rounded.rounded() {
        return "\(Int(rounded))\(suffix)"
    }
    return String(format: "%.1f%@", rounded, suffix)
}

/// Shared helpers for reading the CLIs' append-only JSONL session logs.
enum TokenLog {
    /// Skip any single log file larger than this; real session files are far smaller, and this caps
    /// the work a pathological or unrelated file can cause.
    static let maxFileBytes = 64 << 20  // 64 MiB

    /// ISO-8601 timestamps in these logs carry millisecond fractional seconds and a `Z` suffix
    /// (e.g. "2026-07-11T11:17:44.220Z"); tolerate a whole-second variant too. Formatters are made
    /// locally (like the subscription providers do) since `ISO8601DateFormatter` isn't `Sendable`.
    static func parseDate(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    /// Regular `*.jsonl` files under `root` modified at/after `cutoff`. A log containing a line from
    /// today necessarily has a modification date >= the start of today, so filtering on mtime lets us
    /// read only sessions touched today instead of every transcript ever written.
    static func recentJSONLFiles(
        under root: URL, modifiedSince cutoff: Date, fileManager: FileManager = .default
    ) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard
            let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true,
                let modified = values.contentModificationDate,
                modified >= cutoff
            else { continue }
            files.append(url)
        }
        return files
    }

    /// The lines of a log file, or `nil` if it's oversized or unreadable. Empty lines are dropped.
    static func lines(of url: URL) -> [Substring]? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize, size <= maxFileBytes,
            let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
    }
}
