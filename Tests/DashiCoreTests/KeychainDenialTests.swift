import Security
import XCTest

@testable import DashiCore

private let epoch = Date(timeIntervalSince1970: 1_000_000)

/// Reader that answers every read the way a denied keychain prompt does until ``grant(_:)`` hands
/// it a token, and again once ``deny()`` takes it away; counts the reads either way.
private final class DenyingCredentialsReader: ClaudeCredentialsReading, @unchecked Sendable {
    private let lock = NSLock()
    private var readCount = 0
    private var granted: ClaudeOAuthToken?

    var reads: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCount
    }

    func grant(_ token: ClaudeOAuthToken) {
        lock.lock()
        defer { lock.unlock() }
        granted = token
    }

    func deny() {
        lock.lock()
        defer { lock.unlock() }
        granted = nil
    }

    func currentToken() throws -> ClaudeOAuthToken? {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        guard let granted else { throw CredentialsError.keychain(errSecUserCanceled) }
        return granted
    }
}

/// Transport that fails the test if it is called, since a denied read never yields a token to send.
private let unusedTransport: HTTPTransport = { _ in
    XCTFail("transport should not be called when the credentials read is denied")
    throw LimitError.requestFailed("unused")
}

/// Transport answering every request with a usable usage payload.
private let usageTransport: HTTPTransport = { request in
    let body =
        #"{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":5,"resets_at":null}}"#
    let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (Data(body.utf8), response)
}

@MainActor
final class KeychainDenialTests: XCTestCase {
    /// Builds a consented view model over the real provider wiring, reading the clock through `now`.
    private func viewModel(
        reader: DenyingCredentialsReader,
        transport: @escaping HTTPTransport = unusedTransport,
        now: @escaping () -> Date
    ) -> LimitViewModel {
        LimitViewModel(
            provider: ClaudeSubscriptionProvider(
                credentials: reader, transport: transport, now: { epoch }),
            consent: InMemoryConsentStore(true),
            pollInterval: 300,
            now: now)
    }

    /// Polls twice more past the backoff window after a denial, expecting one read and `.terminal`.
    func testDenialStopsLaterScheduledLoadsFromReadingAgain() async {
        let reader = DenyingCredentialsReader()
        var clock = epoch
        let viewModel = viewModel(reader: reader, now: { clock })

        await viewModel.load(reason: .scheduled)
        XCTAssertEqual(reader.reads, 1)

        clock = clock.addingTimeInterval(2000)
        await viewModel.load(reason: .scheduled)
        clock = clock.addingTimeInterval(2000)
        let outcome = await viewModel.load(reason: .scheduled)

        XCTAssertEqual(reader.reads, 1)
        XCTAssertEqual(outcome, .terminal)
    }

    /// Opens the popup past its 60 s coalescing floor after a denial, expecting no second read.
    func testDenialStopsAPopupOpenFromReadingAgain() async {
        let reader = DenyingCredentialsReader()
        var clock = epoch
        let viewModel = viewModel(reader: reader, now: { clock })

        await viewModel.load(reason: .scheduled)
        XCTAssertEqual(reader.reads, 1)

        clock = clock.addingTimeInterval(120)
        await viewModel.load(reason: .popupOpened)

        XCTAssertEqual(reader.reads, 1)
    }

    /// Classifies each keychain status, counting a refused prompt as denied and an unreachable one
    /// as an ordinary failure.
    func testAccessDeniedCoversRefusedPromptsOnly() {
        let statuses: [(OSStatus, Bool)] = [
            (errSecUserCanceled, true),
            (errSecAuthFailed, true),
            (errSecInteractionNotAllowed, false),
            (errSecParam, false),
        ]
        for (status, expected) in statuses {
            XCTAssertEqual(
                CredentialsError.keychain(status).isAccessDenied, expected, "status \(status)")
        }
    }

    /// Retries manually after a denial and grants the prompt, expecting a second read and limits.
    func testManualRetryReadsAgainAndLoadsOnceGranted() async {
        let reader = DenyingCredentialsReader()
        var clock = epoch
        let viewModel = viewModel(reader: reader, transport: usageTransport, now: { clock })

        await viewModel.load(reason: .scheduled)
        XCTAssertEqual(viewModel.state, .keychainDenied)

        reader.grant(ClaudeOAuthToken(accessToken: Secret("t"), expiresAt: nil))
        clock = clock.addingTimeInterval(120)
        let outcome = await viewModel.load(reason: .manual)

        XCTAssertEqual(reader.reads, 2)
        XCTAssertEqual(outcome, .success)
        guard case .loaded = viewModel.state else {
            return XCTFail("expected loaded after a granted retry, got \(viewModel.state)")
        }
    }

    /// Denies the re-read of an expired token after a good load, expecting the denial over the
    /// stale reading.
    func testDenialAfterALoadedReadingShowsDeniedRatherThanStaleLimits() async {
        let reader = DenyingCredentialsReader()
        reader.grant(ClaudeOAuthToken(accessToken: Secret("t"), expiresAt: epoch))
        var clock = epoch
        let viewModel = viewModel(reader: reader, transport: usageTransport, now: { clock })

        await viewModel.load(reason: .scheduled)
        guard case .loaded = viewModel.state else {
            return XCTFail("expected loaded on the first poll, got \(viewModel.state)")
        }

        reader.deny()
        clock = clock.addingTimeInterval(2000)
        let outcome = await viewModel.load(reason: .scheduled)

        XCTAssertEqual(reader.reads, 2)
        XCTAssertEqual(outcome, .terminal)
        XCTAssertEqual(viewModel.state, .keychainDenied)
    }
}
