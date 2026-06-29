import Foundation
import Observation

/// UI-facing state for the limit gauge. Lives in `DashiCore` (no SwiftUI) so it's unit-testable.
public enum LimitState: Equatable, Sendable {
    case loading
    case loaded(SubscriptionLimits)
    case notSignedIn
    case needsReauth
    case failed(String)
}

/// Drives the gauge: asks a ``LimitProvider`` for the current limits and maps fail-closed errors
/// into renderable states.
@Observable
public final class LimitViewModel {
    public private(set) var state: LimitState = .loading
    @ObservationIgnored private let provider: any LimitProvider

    public init(provider: any LimitProvider) {
        self.provider = provider
    }

    @MainActor
    public func load() async {
        do {
            let limits = try await provider.currentLimits()
            state = .loaded(limits)
        } catch LimitError.notSignedIn {
            state = .notSignedIn
        } catch LimitError.needsReauth {
            state = .needsReauth
        } catch let LimitError.requestFailed(message) {
            state = .failed(message)
        } catch {
            state = .failed("Couldn't load usage")
        }
    }
}

/// Formats the time until a window resets, e.g. "2h 13m", "47m", "now", or "—" when unknown.
public func resetCountdown(to resetsAt: Date?, now: Date = Date()) -> String {
    guard let resetsAt else { return "—" }
    let remaining = resetsAt.timeIntervalSince(now)
    if remaining <= 0 { return "now" }
    let totalMinutes = Int(remaining / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
}
