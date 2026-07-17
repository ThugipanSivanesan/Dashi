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

/// Why a fetch is being requested — selects how the throttle treats it:
/// - ``scheduled``: the background poll. Honors the full voluntary spacing and any rate limit.
/// - ``popupOpened``: the user opened the menu. Refreshes past the voluntary spacing so the number
///   is near-live, but coalesces rapid re-opens (``popupMinInterval``) and honors a real rate limit.
/// - ``manual``: the user tapped refresh. Bypasses voluntary spacing and defers to a rate limit only
///   up to ``manualRateLimitCap``, so a long server `Retry-After` can't leave it a dead button.
public enum FetchReason: Sendable {
    case scheduled
    case popupOpened
    case manual
}

/// Drives the gauge: asks a ``LimitProvider`` for the current limits and maps fail-closed errors
/// into renderable states.
@Observable
public final class LimitViewModel {
    public private(set) var state: LimitState
    /// Observed by the view: `true` while the server is actively rate-limiting us (last fetch was a
    /// 429), so the UI can say "showing last reading, retrying" instead of looking silently frozen.
    /// Flips back to `false` on the first non-429 outcome.
    public private(set) var isRateLimited = false
    @ObservationIgnored private let provider: any LimitProvider
    @ObservationIgnored private let consent: any ConsentStore
    @ObservationIgnored private let log: RedactingLog?
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
    /// Earliest time we may retry after a *known* rate limit (HTTP 429). Observed by the view to show
    /// a retry countdown. Even a forced manual refresh honors this, so the user can't hammer us back
    /// into a 429; `nil` when we're not rate-limited.
    public private(set) var rateLimitedUntil: Date?
    /// The last real fetch outcome, returned when a call is coalesced or throttle-skipped so callers
    /// still see a sensible result without a redundant request.
    @ObservationIgnored private var lastOutcome: PollOutcome = .success
    /// When we last actually attempted a fetch (not a throttle-skip). Used to coalesce rapid popup
    /// re-opens so toggling the menu can't burst requests straight into a 429.
    @ObservationIgnored private var lastAttemptAt = Date.distantPast
    /// When the most recent 429 was recorded, so a *manual* refresh can escape a long server
    /// `Retry-After` after ``manualRateLimitCap`` instead of being stuck with no way to refresh.
    @ObservationIgnored private var rateLimitedAt: Date?
    /// Shortest spacing between popup-open fetches. Opening the menu refreshes past the voluntary
    /// poll spacing for a near-live number, but re-opens within this window reuse cached data.
    @ObservationIgnored private let popupMinInterval: TimeInterval
    /// Longest a *manual* refresh will defer to a server rate limit. The background poll honors the
    /// full `Retry-After`; a user tap waits at most this long, so the button is never dead.
    @ObservationIgnored private let manualRateLimitCap: TimeInterval

    public init(
        provider: any LimitProvider,
        consent: any ConsentStore = UserDefaultsConsentStore(),
        log: RedactingLog? = nil,
        pollInterval: TimeInterval = 300,
        popupMinInterval: TimeInterval = 60,
        manualRateLimitCap: TimeInterval = 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.consent = consent
        self.log = log
        self.backoff = PollBackoff(baseInterval: pollInterval)
        self.popupMinInterval = max(0, popupMinInterval)
        self.manualRateLimitCap = max(0, manualRateLimitCap)
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

    /// Polls ``load(reason:)`` until the surrounding task is cancelled, sleeping until the next
    /// ``load(reason:)``-computed ``nextAllowedFetch`` so the backoff (server `Retry-After`,
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
    /// The `reason` selects the throttle policy (see ``FetchReason`` / ``blockDeadline(for:)``):
    /// the background poll waits out the whole backoff window; a popup-open refreshes past the
    /// voluntary spacing but coalesces rapid re-opens and honors a real rate limit; a manual
    /// refresh honors a rate limit only up to ``manualRateLimitCap``. A throttle-skip reuses the
    /// last outcome and cached state.
    @MainActor
    @discardableResult
    public func load(reason: FetchReason = .scheduled) async -> PollOutcome {
        // Fail closed: never touch the Claude Code token until the user has consented.
        guard consent.hasConsented() else {
            state = .needsConsent
            return .terminal
        }
        // Throttle per reason; skipping reuses the last outcome and cached state.
        if let blockedUntil = blockDeadline(for: reason), now() < blockedUntil {
            return lastOutcome
        }
        // Coalesce overlapping loads: a second caller just reuses whatever the in-flight one produces.
        guard !isLoading else { return lastOutcome }
        isLoading = true
        defer { isLoading = false }

        lastAttemptAt = now()
        let outcome = await fetch()
        lastOutcome = outcome
        // Advance the shared backoff for the next attempt (all paths respect this window).
        let deadline = now().addingTimeInterval(backoff.nextDelay(after: outcome))
        nextAllowedFetch = deadline
        // Only a genuine 429 gates future fetches; record when it happened for the manual escape hatch.
        if case .rateLimited = outcome {
            rateLimitedUntil = deadline
            rateLimitedAt = now()
            isRateLimited = true
        } else {
            rateLimitedUntil = nil
            rateLimitedAt = nil
            isRateLimited = false
        }
        return outcome
    }

    /// The earliest wall-clock time a fetch for `reason` may run, or `nil` if it may run now.
    /// Encapsulates the per-reason throttle policy so ``load(reason:)`` stays a straight line.
    private func blockDeadline(for reason: FetchReason) -> Date? {
        switch reason {
        case .scheduled:
            // Full voluntary spacing (which already folds in any rate-limit/backoff deadline).
            return nextAllowedFetch
        case .popupOpened:
            // Bypass the long voluntary spacing for a near-live number, but coalesce rapid re-opens
            // (the floor) and always defer to a real rate limit so opens can't hammer a 429.
            let floor = lastAttemptAt.addingTimeInterval(popupMinInterval)
            if let rateLimitedUntil { return Swift.max(rateLimitedUntil, floor) }
            return floor
        case .manual:
            // Honor a real rate limit, but only up to the cap so a long server `Retry-After` can't
            // make the refresh button a no-op. Not rate-limited → run immediately.
            guard let rateLimitedUntil, let rateLimitedAt else { return nil }
            return Swift.min(rateLimitedUntil, rateLimitedAt.addingTimeInterval(manualRateLimitCap))
        }
    }

    /// The bare fetch + state mapping, without any throttling — factored out so ``load(reason:)`` can
    /// own the backoff-window bookkeeping in one place.
    @MainActor
    private func fetch() async -> PollOutcome {
        do {
            let limits = try await provider.currentLimits()
            lastLoaded = limits
            state = .loaded(limits)
            log?.info("usage fetch ok")
            return .success
        } catch LimitError.notSignedIn {
            state = .notSignedIn
            log?.info("usage fetch: not signed in")
            return .terminal
        } catch LimitError.needsReauth {
            state = .needsReauth
            log?.info("usage fetch: needs reauth")
            return .terminal
        } catch LimitError.rateLimited(let retryAfter) {
            // Prefer the last good reading; if we've never loaded, stay on the spinner (we're still
            // trying) rather than flashing a hard error while we back off.
            if let lastLoaded {
                state = .loaded(lastLoaded)
            } else {
                state = .loading
            }
            log?.info(
                "usage fetch rate-limited (429), retryAfter=\(retryAfter.map { String($0) } ?? "nil")"
            )
            return .rateLimited(retryAfter: retryAfter)
        } catch LimitError.requestFailed(let message) {
            showStaleOrError(message)
            log?.error("usage fetch failed: \(message)")
            return .transientFailure
        } catch {
            let message = "Couldn't load usage"
            showStaleOrError(message)
            log?.error("usage fetch failed: \(message)")
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
