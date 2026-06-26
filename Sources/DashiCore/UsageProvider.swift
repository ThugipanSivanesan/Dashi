import Foundation

/// Errors a ``UsageProvider`` can surface. `notConnected` is the fail-closed signal when no
/// credential is present — the UI turns it into a "Connect …" prompt rather than crashing.
public enum UsageError: Error, Equatable {
    case notConnected(Provider)
    case requestFailed(String)
}

/// Source of daily usage data. The offline stub is the default so the app and the whole test
/// suite run with no network, no credentials, and no spend; live providers are opt-in.
public protocol UsageProvider: Sendable {
    func todayUsage() async throws -> UsageSummary
}
