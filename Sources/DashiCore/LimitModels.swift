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

/// Snapshot of the Claude subscription's rolling limits, as returned by the OAuth usage endpoint.
public struct SubscriptionLimits: Sendable, Equatable {
    public let fiveHour: RollingLimit
    public let sevenDay: RollingLimit
    public let fetchedAt: Date

    public init(fiveHour: RollingLimit, sevenDay: RollingLimit, fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fetchedAt = fetchedAt
    }
}

/// Fail-closed error states for reading subscription limits.
public enum LimitError: Error, Equatable {
    /// No Claude Code credentials were found locally.
    case notSignedIn
    /// The token was rejected (expired/revoked) — the user must re-authenticate in Claude Code.
    case needsReauth
    case requestFailed(String)
}

/// Source of the Claude subscription's rolling limits.
public protocol LimitProvider: Sendable {
    func currentLimits() async throws -> SubscriptionLimits
}
