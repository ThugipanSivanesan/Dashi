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
    @ObservationIgnored private let now: () -> Date
    /// Most recent successful reading. Kept so a transient failure or a rate-limit backoff shows
    /// stale-but-valid data instead of flashing an error.
    @ObservationIgnored private var lastLoaded: SubscriptionLimits?
    /// Guards against overlapping loads (poll loop + a menu-open or manual refresh firing at once),
    /// which would waste a request and risk tripping the very rate limit we're avoiding.
    @ObservationIgnored private var isLoading = false
    /// Shared backoff so *every* fetch path — the poll loop, popup-open, manual refresh — spaces
    /// requests, instead of only the poll loop honoring it (the bug that let menu-opens hammer 429s).
    @ObservationIgnored private var backoff: PollBackoff
    /// Earliest wall-clock time an ordinary (non-forced) fetch may run again. Advanced after every
    /// attempt from the backoff, so a popup-open inside the window reuses cached data instead of
    /// firing a request straight back into the limit.
    @ObservationIgnored private var nextAllowedFetch = Date.distantPast
    /// Earliest time we may retry after a *known* rate limit (HTTP 429). Even a forced manual refresh
    /// honors this, so the user can't hammer us back into a 429; `nil` when we're not rate-limited.
    @ObservationIgnored private var rateLimitedUntil: Date?
    /// The last real fetch outcome, returned when a call is coalesced or throttle-skipped so callers
    /// still see a sensible result without a redundant request.
    @ObservationIgnored private var lastOutcome: PollOutcome = .success

    public init(
        provider: any LimitProvider,
        consent: any ConsentStore = UserDefaultsConsentStore(),
        pollInterval: TimeInterval = 90,
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.consent = consent
        self.backoff = PollBackoff(baseInterval: pollInterval)
        self.now = now
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

    /// Polls ``load(force:)`` until the surrounding task is cancelled, sleeping until the next
    /// ``load(force:)``-computed ``nextAllowedFetch`` so the backoff (server `Retry-After`,
    /// exponential on repeated failures, jitter) governs cadence for every fetch path uniformly.
    @MainActor
    public func poll() async {
        while !Task.isCancelled {
            await load()
            let delay = max(0, nextAllowedFetch.timeIntervalSince(now()))
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return  // cancelled
            }
        }
    }

    /// Fetches the current limits and maps the result into a renderable ``state``, advancing the
    /// backoff window so the next fetch is spaced correctly. Returns the ``PollOutcome``.
    ///
    /// Ordinary calls (poll loop, popup-open) skip the network while inside the backoff window and
    /// keep showing cached data. `force` (the manual refresh button) fetches early past our
    /// *voluntary* spacing — but still honors a *known* rate limit (``rateLimitedUntil``) so it can't
    /// re-trip a 429.
    @MainActor
    @discardableResult
    public func load(force: Bool = false) async -> PollOutcome {
        // Fail closed: never touch the Claude Code token until the user has consented.
        guard consent.hasConsented() else {
            state = .needsConsent
            return .terminal
        }
        // Throttle: a non-forced call waits out the whole backoff window; a forced call only waits
        // out a real rate limit. Either way, skipping reuses the last outcome and cached state.
        let blockedUntil: Date? = force ? rateLimitedUntil : nextAllowedFetch
        if let blockedUntil, now() < blockedUntil { return lastOutcome }
        // Coalesce overlapping loads: a second caller just reuses whatever the in-flight one produces.
        guard !isLoading else { return lastOutcome }
        isLoading = true
        defer { isLoading = false }

        let outcome = await fetch()
        lastOutcome = outcome
        // Advance the shared backoff for the next attempt (all paths respect this window).
        let deadline = now().addingTimeInterval(backoff.nextDelay(after: outcome))
        nextAllowedFetch = deadline
        // Only a genuine 429 gates a forced refresh; transient/network errors don't.
        if case .rateLimited = outcome {
            rateLimitedUntil = deadline
        } else {
            rateLimitedUntil = nil
        }
        return outcome
    }

    /// The bare fetch + state mapping, without any throttling — factored out so ``load(force:)`` can
    /// own the backoff-window bookkeeping in one place.
    @MainActor
    private func fetch() async -> PollOutcome {
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
            // Prefer the last good reading; if we've never loaded, stay on the spinner (we're still
            // trying) rather than flashing a hard error while we back off.
            if let lastLoaded {
                state = .loaded(lastLoaded)
            } else {
                state = .loading
            }
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
