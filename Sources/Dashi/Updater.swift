import Combine
import Sparkle
import SwiftUI

/// Wraps Sparkle's standard updater for the menu-bar app.
///
/// Sparkle only matters for the notarized distributable build. Until an update-signing key is
/// configured (`SUPublicEDKey` in `App/Info.plist`, generated with Sparkle's `generate_keys`), the
/// updater stays inert and "Check for Updates…" is disabled — an unconfigured ad-hoc build never
/// trips Sparkle's missing-key abort. See RELEASING.md for the one-time key + feed setup.
///
/// `@MainActor` because Sparkle's `SPUUpdater` is main-actor isolated and the app drives it from
/// SwiftUI.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController
    /// Mirrors Sparkle's own readiness flag; drives whether the menu item is enabled.
    @Published var canCheckForUpdates = false

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let configured = !(key ?? "").isEmpty
        controller = SPUStandardUpdaterController(
            startingUpdater: configured, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Presents Sparkle's standard "check for updates" flow.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
