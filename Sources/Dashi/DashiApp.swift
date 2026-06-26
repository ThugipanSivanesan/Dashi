import AppKit
import DashiCore
import SwiftUI

/// Entry point for the Dashi menu bar app. Builds the usage provider from configuration (offline
/// by default) and renders today's usage in the popup.
@main
struct DashiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let provider: any UsageProvider = makeUsageProvider(Settings.fromEnvironment())

    var body: some Scene {
        MenuBarExtra("Dashi", systemImage: "chart.bar") {
            UsageView(provider: provider)
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
