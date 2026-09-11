import Foundation

/// A rolling usage window (e.g. Claude's 5-hour or 7-day allowance).
public struct RollingLimit: Sendable, Equatable {
    /// Percentage of the allowance used so far, 0...100.
    public let utilization: Double
    /// When the window resets, or `nil` if the API didn't report one.
    public let resetsAt: Date?

    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

/// One reported usage window, with the display title and the kind of allowance it measures.
public struct LimitWindow: Sendable, Equatable {
    /// Which allowance a window measures: the session, the whole week, or one model's week.
    public enum Kind: Sendable, Equatable {
        case session
        case weekly
        case weeklyScoped
    }

    public let title: String
    public let kind: Kind
    public let limit: RollingLimit

    public init(title: String, kind: Kind, limit: RollingLimit) {
        self.title = title
        self.kind = kind
        self.limit = limit
    }
}

/// Snapshot of the subscription's rolling limits, as returned by a provider usage endpoint.
/// A window the provider did not report is absent from `windows`.
public struct SubscriptionLimits: Sendable, Equatable {
    public let windows: [LimitWindow]
    public let fetchedAt: Date

    /// The session window, or `nil` when the provider reported none.
    public var fiveHour: RollingLimit? { windows.first { $0.kind == .session }?.limit }
    /// The whole-subscription weekly window, ignoring any per-model weekly window.
    public var sevenDay: RollingLimit? { windows.first { $0.kind == .weekly }?.limit }

    public init(windows: [LimitWindow], fetchedAt: Date) {
        self.windows = windows
        self.fetchedAt = fetchedAt
    }

    /// Builds the two named windows a provider reporting only a session and a weekly allowance has,
    /// omitting either window whose limit is `nil`.
    public init(fiveHour: RollingLimit?, sevenDay: RollingLimit?, fetchedAt: Date) {
        self.init(
            windows: [
                fiveHour.map { LimitWindow(title: "5-hour", kind: .session, limit: $0) },
                sevenDay.map { LimitWindow(title: "Weekly", kind: .weekly, limit: $0) },
            ].compactMap { $0 },
            fetchedAt: fetchedAt
        )
    }
}

/// Fail-closed error states for reading subscription limits.
public enum LimitError: Error, Equatable {
    /// No Claude Code credentials were found locally.
    case notSignedIn
    /// The token was rejected (expired/revoked) — the user must re-authenticate in Claude Code.
    case needsReauth
    /// The usage endpoint returned HTTP 429. `retryAfter` is the server's `Retry-After` value in
    /// seconds when it provided one, so the caller can wait at least that long before retrying.
    case rateLimited(retryAfter: TimeInterval?)
    case requestFailed(String)
}

/// Source of the Claude subscription's rolling limits.
public protocol LimitProvider: Sendable {
    func currentLimits() async throws -> SubscriptionLimits
}
