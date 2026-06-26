import AppKit
import DashiCore
import SwiftUI

/// Entry point for the Dashi menu bar app. The real usage popup is added in the usage-popup
/// feature slice; this baseline shows a minimal placeholder so the app builds and runs.
@main
struct DashiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Dashi", systemImage: "chart.bar") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Dashi").font(.headline)
                Text("AI token usage").foregroundStyle(.secondary)
                Divider()
                Button("Quit Dashi") { NSApplication.shared.terminate(nil) }
            }
            .padding(12)
            .frame(width: 220)
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
