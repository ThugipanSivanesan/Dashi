import Foundation

/// Sums today's Codex token usage from the Codex CLI's session rollouts under
/// `~/.codex/sessions/**/*.jsonl` (or `$CODEX_HOME/sessions`). Each turn emits a `token_count` event
/// whose `payload.info.last_token_usage` is the *per-turn* delta (not the running total), so summing
/// those deltas for lines dated today gives the day's usage. Read-only: Dashi never writes them.
public struct CodexDailyTokenSource: DailyTokenSource {
    private let sessionsDirectory: URL
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(
        sessionsDirectory: URL = CodexDailyTokenSource.defaultSessionsDirectory(),
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.now = now
        self.calendar = calendar
    }

    /// `$CODEX_HOME/sessions` when `CODEX_HOME` is set and non-empty, else `~/.codex/sessions` —
    /// matching how the Codex credential reader resolves its home.
    public static func defaultSessionsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let base: URL
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            base = URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
        } else {
            base = home.appendingPathComponent(".codex")
        }
        return base.appendingPathComponent("sessions")
    }

    public func tokensToday() -> ProviderDailyTokens? {
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else { return nil }
        let startOfToday = calendar.startOfDay(for: now())
        let files = TokenLog.recentJSONLFiles(under: sessionsDirectory, modifiedSince: startOfToday)
        var total = ProviderDailyTokens.zero
        // Guards against the same turn appearing twice (e.g. a replayed rollout): a turn is keyed by
        // its timestamp + total, which differ between distinct turns.
        var seen = Set<String>()
        for file in files {
            guard let lines = TokenLog.lines(of: file) else { continue }
            total =
                total + Self.aggregate(lines: lines, now: now(), calendar: calendar, seen: &seen)
        }
        return total
    }

    /// One JSONL line of a Codex session rollout. Token usage lives on `token_count` events.
    private struct Line: Decodable {
        let timestamp: String?
        let payload: Payload?
        struct Payload: Decodable {
            let type: String?
            let info: Info?
            struct Info: Decodable {
                let lastTokenUsage: Usage?
            }
            struct Usage: Decodable {
                let inputTokens: Int?
                let cachedInputTokens: Int?
                let outputTokens: Int?
            }
        }
    }

    /// Sums the per-turn `last_token_usage` of `token_count` lines dated today. Codex folds cached
    /// input into `input_tokens`, so we split it back out: fresh input = input − cached, and cached
    /// maps to the cache-read bucket, keeping the breakdown consistent with the Claude source.
    static func aggregate(
        lines: some Sequence<Substring>, now: Date, calendar: Calendar, seen: inout Set<String>
    ) -> ProviderDailyTokens {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var total = ProviderDailyTokens.zero
        for line in lines {
            guard let decoded = try? decoder.decode(Line.self, from: Data(line.utf8)),
                decoded.payload?.type == "token_count",
                let usage = decoded.payload?.info?.lastTokenUsage,
                let timestamp = decoded.timestamp,
                let stamp = TokenLog.parseDate(timestamp),
                calendar.isDate(stamp, inSameDayAs: now)
            else { continue }
            let cached = usage.cachedInputTokens ?? 0
            let input = usage.inputTokens ?? 0
            let key = "\(timestamp)|\(input)|\(usage.outputTokens ?? 0)"
            guard seen.insert(key).inserted else { continue }
            total =
                total
                + ProviderDailyTokens(
                    inputTokens: max(0, input - cached),
                    outputTokens: usage.outputTokens ?? 0,
                    cacheCreationTokens: 0,
                    cacheReadTokens: cached)
        }
        return total
    }
}
