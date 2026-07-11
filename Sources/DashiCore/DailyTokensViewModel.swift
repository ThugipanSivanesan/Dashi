import Foundation
import Observation

/// Drives the "tokens used today" readout: reads each provider's local logs off the main thread and
/// publishes a ``DailyTokens`` snapshot. Reading local files is cheap and never rate-limited (unlike
/// the usage endpoints), so this just refreshes on demand — no backoff needed.
@Observable
public final class DailyTokensViewModel {
    /// The latest snapshot, or `nil` until the first load completes.
    public private(set) var tokens: DailyTokens?

    @ObservationIgnored private let claudeSource: any DailyTokenSource
    @ObservationIgnored private let codexSource: any DailyTokenSource
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Coalesces overlapping loads (popup-open and manual refresh firing together).
    @ObservationIgnored private var isLoading = false

    public init(
        claudeSource: any DailyTokenSource = ClaudeDailyTokenSource(),
        codexSource: any DailyTokenSource = CodexDailyTokenSource(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.claudeSource = claudeSource
        self.codexSource = codexSource
        self.now = now
    }

    @MainActor
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let claudeSource = self.claudeSource
        let codexSource = self.codexSource
        let now = self.now
        // File IO on a background task so scanning transcripts never blocks the menu.
        tokens = await Task.detached(priority: .utility) {
            DailyTokens(
                claude: claudeSource.tokensToday(),
                codex: codexSource.tokensToday(),
                fetchedAt: now())
        }.value
    }
}
