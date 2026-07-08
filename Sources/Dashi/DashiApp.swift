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
    @StateObject private var updater = Updater()
    private let sharedConsent: UserDefaultsConsentStore
    private let pollInterval = Settings.fromEnvironment().pollInterval

    init() {
        let consent = UserDefaultsConsentStore()
        sharedConsent = consent
        _claudeViewModel = State(
            initialValue: LimitViewModel(
                provider: ClaudeSubscriptionProvider(), consent: consent))
        _codexViewModel = State(
            initialValue: LimitViewModel(
                provider: CodexSubscriptionProvider(), consent: consent))
    }

    var body: some Scene {
        MenuBarExtra {
            LimitView(
                claudeViewModel: claudeViewModel,
                codexViewModel: codexViewModel,
                consent: sharedConsent,
                updater: updater)
        } label: {
            LimitMenuBarLabel(
                claudeViewModel: claudeViewModel, codexViewModel: codexViewModel
            )
            // Each provider polls on its own task so one hitting a rate limit backs off
            // independently instead of dragging the other's cadence with it.
            .task { await claudeViewModel.poll(interval: pollInterval) }
            .task { await codexViewModel.poll(interval: pollInterval) }
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
