import Foundation
import Observation

/// UI-facing state for the usage popup. Lives in `DashiCore` (no SwiftUI dependency) so the state
/// machine is unit-testable; the SwiftUI view merely renders it.
public enum UsageState: Equatable, Sendable {
    case loading
    case loaded(UsageSummary)
    case empty
    case failed(String)
}

/// Drives the popup: asks a ``UsageProvider`` for today's usage and maps the result — including
/// fail-closed `notConnected` errors — into a renderable ``UsageState``.
@Observable
public final class UsageViewModel {
    public private(set) var state: UsageState = .loading
    @ObservationIgnored private let provider: any UsageProvider

    public init(provider: any UsageProvider) {
        self.provider = provider
    }

    @MainActor
    public func load() async {
        state = .loading
        do {
            let summary = try await provider.todayUsage()
            state = summary.providers.isEmpty ? .empty : .loaded(summary)
        } catch UsageError.notConnected(let provider) {
            state = .failed("Connect your \(provider.displayName) account")
        } catch UsageError.requestFailed(let message) {
            state = .failed(message)
        } catch {
            state = .failed("Couldn't load usage")
        }
    }
}
