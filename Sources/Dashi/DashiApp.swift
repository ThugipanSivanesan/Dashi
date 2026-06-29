import AppKit
import DashiCore
import SwiftUI

/// Entry point for the Dashi menu bar app. Shows the Claude subscription's 5-hour limit at a glance
/// in the menu bar and refreshes it on a timer.
@main
struct DashiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel = LimitViewModel(provider: ClaudeSubscriptionProvider())
    private let pollInterval = Settings.fromEnvironment().pollInterval

    var body: some Scene {
        MenuBarExtra {
            LimitView(viewModel: viewModel)
        } label: {
            LimitMenuBarLabel(viewModel: viewModel)
                .task {
                    while !Task.isCancelled {
                        await viewModel.load()
                        try? await Task.sleep(for: .seconds(pollInterval))
                    }
                }
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
