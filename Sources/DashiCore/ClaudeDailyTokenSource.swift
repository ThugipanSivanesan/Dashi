import Foundation

/// Sums today's Claude token usage from Claude Code's local transcripts under
/// `~/.claude/projects/*/*.jsonl`. Each assistant turn records a `message.usage` block; we bucket by
/// the per-line `timestamp` (UTC) into the current *local* calendar day and dedupe retried/branched
/// turns by their request/message ids. Read-only: Dashi never writes these files.
public struct ClaudeDailyTokenSource: DailyTokenSource {
    private let projectsDirectory: URL
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(
        projectsDirectory: URL = ClaudeDailyTokenSource.defaultProjectsDirectory(),
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.projectsDirectory = projectsDirectory
        self.now = now
        self.calendar = calendar
    }

    /// `~/.claude/projects` — the transcript root Claude Code writes.
    public static func defaultProjectsDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".claude/projects")
    }

    public func tokensToday() -> ProviderDailyTokens? {
        guard FileManager.default.fileExists(atPath: projectsDirectory.path) else { return nil }
        let startOfToday = calendar.startOfDay(for: now())
        let files = TokenLog.recentJSONLFiles(under: projectsDirectory, modifiedSince: startOfToday)
        var total = ProviderDailyTokens.zero
        // Shared across files so a turn duplicated by a resumed/branched session is counted once.
        var seen = Set<String>()
        for file in files {
            guard let lines = TokenLog.lines(of: file) else { continue }
            total =
                total + Self.aggregate(lines: lines, now: now(), calendar: calendar, seen: &seen)
        }
        return total
    }

    /// One JSONL line of a Claude Code transcript. Only assistant turns carry a `usage` block; the
    /// top-level `requestId` and `message.id` identify a turn for deduplication.
    private struct Line: Decodable {
        let timestamp: String?
        let requestId: String?
        let message: Message?
        struct Message: Decodable {
            let id: String?
            let usage: Usage?
        }
        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
        }
    }

    /// Sums the usage of the lines whose timestamp falls on `now`'s local calendar day, skipping any
    /// turn whose id pair was already counted (via the shared `seen` set).
    static func aggregate(
        lines: some Sequence<Substring>, now: Date, calendar: Calendar, seen: inout Set<String>
    ) -> ProviderDailyTokens {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var total = ProviderDailyTokens.zero
        for line in lines {
            guard let decoded = try? decoder.decode(Line.self, from: Data(line.utf8)),
                let usage = decoded.message?.usage,
                let stamp = decoded.timestamp.flatMap(TokenLog.parseDate),
                calendar.isDate(stamp, inSameDayAs: now)
            else { continue }
            // Dedupe only when we have an id to key on; unidentified turns are counted as-is rather
            // than collapsed together.
            if decoded.requestId != nil || decoded.message?.id != nil {
                let key = "\(decoded.requestId ?? "")|\(decoded.message?.id ?? "")"
                guard seen.insert(key).inserted else { continue }
            }
            total =
                total
                + ProviderDailyTokens(
                    inputTokens: usage.inputTokens ?? 0,
                    outputTokens: usage.outputTokens ?? 0,
                    cacheCreationTokens: usage.cacheCreationInputTokens ?? 0,
                    cacheReadTokens: usage.cacheReadInputTokens ?? 0)
        }
        return total
    }
}
