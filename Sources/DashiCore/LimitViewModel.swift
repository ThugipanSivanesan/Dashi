import Foundation
import Observation

/// UI-facing state for the limit gauge. Lives in `DashiCore` (no SwiftUI) so it's unit-testable.
public enum LimitState: Equatable, Sendable {
    case loading
    case loaded(SubscriptionLimits)
    case needsConsent
    case notSignedIn
    case needsReauth
    case failed(String)
}

/// Drives the gauge: asks a ``LimitProvider`` for the current limits and maps fail-closed errors
/// into renderable states.
@Observable
public final class LimitViewModel {
    public private(set) var state: LimitState
    @ObservationIgnored private let provider: any LimitProvider
    @ObservationIgnored private let consent: any ConsentStore

    public init(
        provider: any LimitProvider,
        consent: any ConsentStore = UserDefaultsConsentStore()
    ) {
        self.provider = provider
        self.consent = consent
        // Start gated until the user accepts the experimental/ToS terms — avoids a flash of the
        // gauge before consent and ensures the token is never read without it.
        self.state = consent.hasConsented() ? .loading : .needsConsent
    }

    /// Records consent (the user accepted the experimental/ToS terms) and loads immediately.
    @MainActor
    public func grantConsent() async {
        consent.setConsented(true)
        await load()
    }

    @MainActor
    public func load() async {
        // Fail closed: never touch the Claude Code token until the user has consented.
        guard consent.hasConsented() else {
            state = .needsConsent
            return
        }
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

/// Formats when a window resets as a day + local time, e.g. "Mon at 11:00 AM",
/// "today at 11:00 AM", "tomorrow at 11:00 AM", or "—" when unknown. Used for the weekly window,
/// where a concrete day reads better than a seconds-ticking countdown.
public func resetDayTime(
    to resetsAt: Date?, now: Date = Date(), calendar: Calendar = .current
) -> String {
    guard let resetsAt else { return "—" }
    let time = resetsAt.formatted(date: .omitted, time: .shortened)
    let day: String
    if calendar.isDate(resetsAt, inSameDayAs: now) {
        day = "today"
    } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
        calendar.isDate(resetsAt, inSameDayAs: tomorrow)
    {
        day = "tomorrow"
    } else {
        day = resetsAt.formatted(.dateTime.weekday(.abbreviated))
    }
    return "\(day) at \(time)"
}
