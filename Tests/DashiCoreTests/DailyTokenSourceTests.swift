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
}
