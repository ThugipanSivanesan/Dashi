import AppKit
import DashiCore
import SwiftUI

/// Entry point for the Dashi menu bar app. Shows the highest 5-hour utilization at a glance and
/// refreshes both providers on a timer.
@main
struct DashiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var claudeViewModel: LimitViewModel
    @State private var codexViewModel: LimitViewModel
    @State private var dailyTokensViewModel: DailyTokensViewModel
    @StateObject private var updater = Updater()
    private let sharedConsent: UserDefaultsConsentStore

    init() {
        let consent = UserDefaultsConsentStore()
        sharedConsent = consent
        let interval = Settings.fromEnvironment().pollInterval
        _claudeViewModel = State(
            initialValue: LimitViewModel(
                provider: ClaudeSubscriptionProvider(), consent: consent, pollInterval: interval))
        _codexViewModel = State(
            initialValue: LimitViewModel(
                provider: CodexSubscriptionProvider(), consent: consent, pollInterval: interval))
        _dailyTokensViewModel = State(initialValue: DailyTokensViewModel())
    }

    var body: some Scene {
        MenuBarExtra {
            LimitView(
                claudeViewModel: claudeViewModel,
                codexViewModel: codexViewModel,
                dailyTokensViewModel: dailyTokensViewModel,
                consent: sharedConsent,
                updater: updater)
        } label: {
            LimitMenuBarLabel(
                claudeViewModel: claudeViewModel, codexViewModel: codexViewModel
            )
            // Each provider polls on its own task so one hitting a rate limit backs off
            // independently instead of dragging the other's cadence with it.
            .task { await claudeViewModel.poll() }
            .task { await codexViewModel.poll() }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Hides the Dock icon so Dashi lives only in the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
