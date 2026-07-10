import AppKit
import DashiCore
import SwiftUI

/// Compact menu-bar readout for both providers' 5-hour utilization.
struct LimitMenuBarLabel: View {
    let claudeViewModel: LimitViewModel
    let codexViewModel: LimitViewModel

    var body: some View {
        Image(nsImage: renderedImage)
    }

    private var renderedImage: NSImage {
        let content = HStack(spacing: 6) {
            ProviderMenuBarChip(state: claudeViewModel.state, label: "CC")
            ProviderMenuBarChip(state: codexViewModel.state, label: "CX")
        }
        .fixedSize()
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}

private struct ProviderMenuBarChip: View {
    let state: LimitState
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.body)
            Text(percentageText)
                .monospacedDigit()
        }
        .foregroundStyle(.black)
        .opacity(isLoaded ? 1 : 0.55)
    }

    private var percentageText: String {
        switch state {
        case .loaded(let limits):
            "\(Int(limits.fiveHour.utilization.rounded()))%"
        case .loading:
            "…"
        case .notSignedIn, .needsReauth, .needsConsent, .failed:
            "–"
        }
    }

    private var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }
}

/// The popup: one shared consent gate followed by Claude and Codex usage gauges.
struct LimitView: View {
    let claudeViewModel: LimitViewModel
    let codexViewModel: LimitViewModel
    let consent: UserDefaultsConsentStore
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if consent.hasConsented() {
                LimitSection(
                    title: "Claude",
                    viewModel: claudeViewModel,
                    notSignedIn: "Log in to Claude Code to see your usage.",
                    needsReauth: "Your Claude session expired — re-authenticate in Claude Code.")
                Divider()
                LimitSection(
                    title: "Codex",
                    viewModel: codexViewModel,
                    notSignedIn: "Open the Codex CLI (run `codex`) and log in to see your usage.",
                    needsReauth: "Your Codex session expired — run `codex` to re-authenticate.")
            } else {
                consentPrompt
            }

            Divider()
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
            Button("Quit Dashi") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
        // Refresh past the voluntary poll spacing when the popup opens so the number you're looking
        // at is near-live, not a cached reading up to a poll-interval old. Rapid re-opens coalesce
        // (popupMinInterval) and a real rate limit is still honored, so opening the menu can't burst
        // requests into a 429. The background poll stays at its gentle cadence.
        .task {
            await claudeViewModel.load(reason: .popupOpened)
            await codexViewModel.load(reason: .popupOpened)
        }
    }

    private var header: some View {
        HStack {
            Text("Usage").font(.headline)
            Spacer()
            Button {
                Task {
                    await claudeViewModel.load(reason: .manual)
                    await codexViewModel.load(reason: .manual)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
    }

    private var consentPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Experimental feature", systemImage: "exclamationmark.shield")
                .font(.callout)
                .foregroundStyle(.orange)
            Text(
                "Showing your Claude and Codex usage reuses each tool's local login token "
                    + "(from Claude Code and the Codex CLI) to call unofficial usage endpoints. "
                    + "This is a personal-use feature that may violate the providers' Terms of "
                    + "Service and could stop working without notice."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let url = URL(
                string: "https://github.com/ThugipanSivanesan/Dashi/blob/main/SECURITY.md")
            {
                Link("Learn more", destination: url).font(.caption)
            }
            Button("Enable usage gauges") {
                Task {
                    await claudeViewModel.grantConsent()
                    await codexViewModel.grantConsent()
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
        }
    }
}

/// A provider-specific usage section backed by a shared state renderer.
private struct LimitSection: View {
    let title: String
    let viewModel: LimitViewModel
    let notSignedIn: String
    let needsReauth: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading, .needsConsent:
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        case .loaded(let limits):
            limitsView(limits)
        case .notSignedIn:
            message(notSignedIn, systemImage: "person.crop.circle.badge.questionmark")
        case .needsReauth:
            message(needsReauth, systemImage: "exclamationmark.triangle")
        case .failed(let text):
            message(text, systemImage: "exclamationmark.triangle")
        }
    }

    private func limitsView(_ limits: SubscriptionLimits) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            windowRow(
                title: "5-hour", limit: limits.fiveHour, prominent: true, liveCountdown: true)
            windowRow(
                title: "Weekly", limit: limits.sevenDay, prominent: false, liveCountdown: false)
            Text("Updated \(limits.fetchedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func windowRow(
        title: String, limit: RollingLimit, prominent: Bool, liveCountdown: Bool
    ) -> some View {
        let pct = Int(limit.utilization.rounded())
        let hot = pct >= 90
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(prominent ? .headline : .subheadline)
                Spacer()
                Text("\(pct)% used")
                    .monospacedDigit()
                    .foregroundStyle(hot ? Color.red : Color.primary)
            }
            ProgressView(value: min(max(limit.utilization, 0), 100), total: 100)
                .tint(hot ? .red : .accentColor)
            resetLabel(for: limit, liveCountdown: liveCountdown)
        }
    }

    @ViewBuilder
    private func resetLabel(for limit: RollingLimit, liveCountdown: Bool) -> some View {
        if liveCountdown {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("resets in \(resetCountdown(to: limit.resetsAt, now: context.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("resets \(resetDayTime(to: limit.resetsAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
