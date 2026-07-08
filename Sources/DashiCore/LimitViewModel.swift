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
    /// Most recent successful reading. Kept so a transient failure or a rate-limit backoff shows
    /// stale-but-valid data instead of flashing an error.
    @ObservationIgnored private var lastLoaded: SubscriptionLimits?
    /// Guards against overlapping loads (poll loop + a menu-open or manual refresh firing at once),
    /// which would waste a request and risk tripping the very rate limit we're avoiding.
    @ObservationIgnored private var isLoading = false

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

    /// Polls ``load()`` until the surrounding task is cancelled, spacing requests with
    /// ``PollBackoff`` (honors the server's `Retry-After`, backs off on repeated failures, adds
    /// jitter). `interval` is the normal cadence between successful polls.
    @MainActor
    public func poll(interval: TimeInterval) async {
        var backoff = PollBackoff(baseInterval: interval)
        while !Task.isCancelled {
            let outcome = await load()
            do {
                try await Task.sleep(for: .seconds(backoff.nextDelay(after: outcome)))
            } catch {
                return  // cancelled
            }
        }
    }

    /// Fetches the current limits and maps the result into a renderable ``state``. Returns the
    /// ``PollOutcome`` so a caller like ``poll(interval:)`` can decide how long to wait next.
    @MainActor
    @discardableResult
    public func load() async -> PollOutcome {
        // Fail closed: never touch the Claude Code token until the user has consented.
        guard consent.hasConsented() else {
            state = .needsConsent
            return .terminal
        }
        // Coalesce overlapping loads: a second caller just reuses whatever the in-flight one produces.
        guard !isLoading else { return .success }
        isLoading = true
        defer { isLoading = false }

        do {
            let limits = try await provider.currentLimits()
            lastLoaded = limits
            state = .loaded(limits)
            return .success
        } catch LimitError.notSignedIn {
            state = .notSignedIn
            return .terminal
        } catch LimitError.needsReauth {
            state = .needsReauth
            return .terminal
        } catch LimitError.rateLimited(let retryAfter) {
            showStaleOrError("Rate limited — retrying soon")
            return .rateLimited(retryAfter: retryAfter)
        } catch LimitError.requestFailed(let message) {
            showStaleOrError(message)
            return .transientFailure
        } catch {
            showStaleOrError("Couldn't load usage")
            return .transientFailure
        }
    }

    /// Prefers the last good reading over an error flash; only surfaces the error when we've never
    /// managed a successful load.
    @MainActor
    private func showStaleOrError(_ message: String) {
        if let lastLoaded {
            state = .loaded(lastLoaded)
        } else {
            state = .failed(message)
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
