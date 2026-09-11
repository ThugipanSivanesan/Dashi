import XCTest

@testable import DashiCore

final class DailyTokenSourceTests: XCTestCase {
    // A fixed "now"; timestamps are derived from it so "same local day" never straddles a boundary.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let calendar = Calendar.current

    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func stamp(_ date: Date) -> String { iso.string(from: date) }
    private var today: String { stamp(now) }
    private var otherDay: String { stamp(now.addingTimeInterval(-26 * 3600)) }

    // MARK: - formatTokenCount

    func testFormatTokenCount() {
        XCTAssertEqual(formatTokenCount(0), "0")
        XCTAssertEqual(formatTokenCount(823), "823")
        XCTAssertEqual(formatTokenCount(5_600), "5.6K")
        XCTAssertEqual(formatTokenCount(12_340), "12.3K")
        XCTAssertEqual(formatTokenCount(340_000), "340K")
        XCTAssertEqual(formatTokenCount(1_200_000), "1.2M")
        XCTAssertEqual(formatTokenCount(1_000_000), "1M")
        XCTAssertEqual(formatTokenCount(3_400_000_000), "3.4B")
    }

    /// Counts just under a unit boundary must promote rather than print a four-digit figure: the
    /// unit is picked from the *rounded* value, so 999_950 is `1M`, not `1000K`.
    func testFormatTokenCountPromotesWhenRoundingCrossesAUnit() {
        XCTAssertEqual(formatTokenCount(999_950), "1M")
        XCTAssertEqual(formatTokenCount(999_999), "1M")
        XCTAssertEqual(formatTokenCount(999_999_500), "1B")
        // Just below each promotion point the smaller unit is still the right one.
        XCTAssertEqual(formatTokenCount(999_949), "999.9K")
        XCTAssertEqual(formatTokenCount(999_949_999), "999.9M")
        // The sign is re-attached after promotion, not lost in the new branch.
        XCTAssertEqual(formatTokenCount(-999_950), "-1M")
        // `B` is the largest unit there is, so at the top of the range four digits are correct —
        // the promotion loop must not try to escape past it. Both counts reach a mantissa of 1000,
        // but only 999_999_949_999 gets there by rounding; 1_000_000_000_000 divides exactly.
        XCTAssertEqual(formatTokenCount(1_000_000_000_000), "1000B")
        XCTAssertEqual(formatTokenCount(999_999_949_999), "1000B")
        // A promotion into the largest unit keeps the sign as well.
        XCTAssertEqual(formatTokenCount(-999_999_500), "-1B")
    }

    func testFormatTokenCountHandlesTheMostNegativeCount() {
        XCTAssertEqual(formatTokenCount(Int.min), formatTokenCount(Int.min + 1))
        XCTAssertEqual(formatTokenCount(Int.min), "-9223372036.9B")
    }

    // MARK: - Claude aggregation

    func testClaudeAggregatesTodaySplitByCategory() {
        let line = """
            {"type":"assistant","timestamp":"\(today)","requestId":"r1","message":{"id":"m1",\
            "usage":{"input_tokens":100,"output_tokens":20,\
            "cache_creation_input_tokens":5,"cache_read_input_tokens":7}}}
            """
        var seen = Set<String>()
        let total = ClaudeDailyTokenSource.aggregate(
            lines: [Substring(line)], now: now, calendar: calendar, seen: &seen)
        XCTAssertEqual(total.inputTokens, 100)
        XCTAssertEqual(total.outputTokens, 20)
        XCTAssertEqual(total.cacheCreationTokens, 5)
        XCTAssertEqual(total.cacheReadTokens, 7)
        XCTAssertEqual(total.total, 132)
    }

    func testClaudeIgnoresOtherDaysAndNonUsageLines() {
        let lines = [
            // yesterday — excluded by timestamp
            """
            {"type":"assistant","timestamp":"\(otherDay)","requestId":"r0","message":{"id":"m0",\
            "usage":{"input_tokens":999,"output_tokens":999}}}
            """,
            // a user turn — no usage block
            #"{"type":"user","timestamp":"\#(today)","message":{"role":"user"}}"#,
            // today — counted
            """
            {"type":"assistant","timestamp":"\(today)","requestId":"r1","message":{"id":"m1",\
            "usage":{"input_tokens":10,"output_tokens":3}}}
            """,
        ]
        var seen = Set<String>()
        let total = ClaudeDailyTokenSource.aggregate(
            lines: lines.map { Substring($0) }, now: now, calendar: calendar, seen: &seen)
        XCTAssertEqual(total.total, 13)
    }

    func testClaudeDedupesRepeatedTurnsAcrossCalls() {
        let line = """
            {"type":"assistant","timestamp":"\(today)","requestId":"r1","message":{"id":"m1",\
            "usage":{"input_tokens":10,"output_tokens":3}}}
            """
        var seen = Set<String>()
        let first = ClaudeDailyTokenSource.aggregate(
            lines: [Substring(line)], now: now, calendar: calendar, seen: &seen)
        // Same turn seen again (e.g. a branched transcript) must not be double-counted.
        let second = ClaudeDailyTokenSource.aggregate(
            lines: [Substring(line)], now: now, calendar: calendar, seen: &seen)
        XCTAssertEqual(first.total, 13)
        XCTAssertEqual(second.total, 0)
    }

    // MARK: - Codex aggregation

    func testCodexAggregatesTodaySplittingCachedInput() {
        let line = """
            {"timestamp":"\(today)","payload":{"type":"token_count","info":{"last_token_usage":\
            {"input_tokens":13090,"cached_input_tokens":10112,"output_tokens":385,\
            "reasoning_output_tokens":198,"total_tokens":13475}}}}
            """
        var seen = Set<String>()
        let total = CodexDailyTokenSource.aggregate(
            lines: [Substring(line)], now: now, calendar: calendar, seen: &seen)
        XCTAssertEqual(total.inputTokens, 2978)  // 13090 − 10112 cached
        XCTAssertEqual(total.cacheReadTokens, 10112)
        XCTAssertEqual(total.outputTokens, 385)
        XCTAssertEqual(total.cacheCreationTokens, 0)
        XCTAssertEqual(total.total, 13475)  // matches Codex's own total_tokens
    }

    func testCodexIgnoresNonTokenCountAndOtherDays() {
        let lines = [
            #"{"timestamp":"\#(today)","payload":{"type":"event_msg"}}"#,
            """
            {"timestamp":"\(otherDay)","payload":{"type":"token_count","info":{"last_token_usage":\
            {"input_tokens":500,"cached_input_tokens":0,"output_tokens":50}}}}
            """,
            """
            {"timestamp":"\(today)","payload":{"type":"token_count","info":{"last_token_usage":\
            {"input_tokens":40,"cached_input_tokens":0,"output_tokens":10}}}}
            """,
        ]
        var seen = Set<String>()
        let total = CodexDailyTokenSource.aggregate(
            lines: lines.map { Substring($0) }, now: now, calendar: calendar, seen: &seen)
        XCTAssertEqual(total.total, 50)
    }

    // MARK: - File walking

    func testClaudeSourceReadsRecentFilesAndSkipsMissingDir() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-\(UUID().uuidString)")
        let fixedNow = now
        let source = ClaudeDailyTokenSource(
            projectsDirectory: root, now: { fixedNow }, calendar: calendar)

        // Missing directory → unavailable (nil), distinct from zero.
        XCTAssertNil(source.tokensToday())

        let project = root.appendingPathComponent("some-project")
        try FileManager.default.createDirectory(
            at: project, withIntermediateDirectories: true)
        let line = """
            {"type":"assistant","timestamp":"\(today)","requestId":"r1","message":{"id":"m1",\
            "usage":{"input_tokens":100,"output_tokens":20}}}
            """
        try Data((line + "\n").utf8)
            .write(to: project.appendingPathComponent("session.jsonl"))

        // No `message.model` on this line, so the tokens count toward the day but can't be priced.
        XCTAssertEqual(
            source.tokensToday(),
            ProviderDailyTokens(inputTokens: 100, outputTokens: 20, unpricedTokens: 120))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    func testClaudeSourceSkipsFilesNotModifiedToday() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-\(UUID().uuidString)")
        let project = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("old.jsonl")
        let line = """
            {"type":"assistant","timestamp":"\(today)","requestId":"r1","message":{"id":"m1",\
            "usage":{"input_tokens":100,"output_tokens":20}}}
            """
        try Data((line + "\n").utf8).write(to: file)
        // Backdate the file: even though its line is timestamped "today", an old mtime means it can't
        // contain today's data, so the scan skips it.
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-3 * 24 * 3600)], ofItemAtPath: file.path)

        let fixedNow = now
        let source = ClaudeDailyTokenSource(
            projectsDirectory: root, now: { fixedNow }, calendar: calendar)
        XCTAssertEqual(source.tokensToday(), .zero)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    /// Pins the per-file accumulation in ``ClaudeDailyTokenSource/tokensToday()``: two counted
    /// transcripts sum, rather than the last one read standing for the day. File enumeration order
    /// is unspecified, so the sum is the only order-independent oracle.
    func testClaudeSourceSumsTokensAcrossFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        // Distinct ids per file: the `seen` set is shared across files, so a reused
        // requestId/message.id pair would drop the second turn as a duplicate.
        for (project, id, input, output) in [("alpha", "a", 100, 20), ("beta", "b", 7, 3)] {
            let directory = root.appendingPathComponent(project)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let line = """
                {"type":"assistant","timestamp":"\(today)","requestId":"r-\(id)",\
                "message":{"id":"m-\(id)","usage":{"input_tokens":\(input),\
                "output_tokens":\(output)}}}
                """
            try Data((line + "\n").utf8)
                .write(to: directory.appendingPathComponent("session.jsonl"))
        }

        let fixedNow = now
        let source = ClaudeDailyTokenSource(
            projectsDirectory: root, now: { fixedNow }, calendar: calendar)
        XCTAssertEqual(
            source.tokensToday(),
            ProviderDailyTokens(inputTokens: 107, outputTokens: 23, unpricedTokens: 130))
    }

    /// Pins the per-file accumulation in ``CodexDailyTokenSource/tokensToday()``: two counted
    /// rollouts sum, rather than the last one read standing for the day.
    func testCodexSourceSumsTokensAcrossFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        // Distinct turns per file: the shared `seen` set keys on timestamp|input|output, so two
        // identical turns would collapse into one and let a dropped file pass unnoticed.
        let later = stamp(now.addingTimeInterval(60))
        for (session, time, input, cached, output) in [
            ("session-a", today, 100, 0, 20), ("session-b", later, 40, 10, 5),
        ] {
            let directory = root.appendingPathComponent(session)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let line = """
                {"timestamp":"\(time)","payload":{"type":"token_count","info":\
                {"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
                "output_tokens":\(output)}}}}
                """
            try Data((line + "\n").utf8)
                .write(to: directory.appendingPathComponent("rollout.jsonl"))
        }

        let fixedNow = now
        let source = CodexDailyTokenSource(
            sessionsDirectory: root, now: { fixedNow }, calendar: calendar)
        // Fresh input is 100 + (40 - 10 cached); Codex turns are never priced, so every token is
        // reported unpriced.
        XCTAssertEqual(
            source.tokensToday(),
            ProviderDailyTokens(
                inputTokens: 130, outputTokens: 25, cacheReadTokens: 10, unpricedTokens: 165))
    }

    /// A missing sessions root reports unavailable, not a day of zero usage — the distinction
    /// ``DailyTokens`` documents, guarded separately from the Claude source's own root check.
    func testCodexSourceReportsMissingDirectoryAsUnavailable() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-\(UUID().uuidString)")
        let fixedNow = now
        let source = CodexDailyTokenSource(
            sessionsDirectory: root, now: { fixedNow }, calendar: calendar)
        XCTAssertNil(source.tokensToday())
    }
}
