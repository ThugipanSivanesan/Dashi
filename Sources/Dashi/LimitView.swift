import AppKit
import DashiCore
import SwiftUI

/// Compact menu-bar readout: the 5-hour utilization at a glance, or a warning glyph.
struct LimitMenuBarLabel: View {
    let viewModel: LimitViewModel

    var body: some View {
        switch viewModel.state {
        case .loading:
            Image(systemName: "gauge.with.dots.needle.50percent")
        case .loaded(let limits):
            Text("\(Int(limits.fiveHour.utilization.rounded()))%")
        case .needsConsent:
            Image(systemName: "exclamationmark.shield")
        case .notSignedIn, .needsReauth:
            Image(systemName: "exclamationmark.triangle.fill")
        case .failed:
            Image(systemName: "gauge.with.dots.needle.0percent")
        }
    }
}

/// The popup: 5-hour and weekly gauges with live reset countdowns.
struct LimitView: View {
    let viewModel: LimitViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude usage").font(.headline)
                Spacer()
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

            content

            Divider()
            Button("Quit Dashi") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        case .loaded(let limits):
            limitsView(limits)
        case .needsConsent:
            consentPrompt
        case .notSignedIn:
            message(
                "Log in to Claude Code to see your usage.",
                systemImage: "person.crop.circle.badge.questionmark")
        case .needsReauth:
            message(
                "Your Claude session expired — re-authenticate in Claude Code.",
                systemImage: "exclamationmark.triangle")
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

    /// The 5-hour window ticks a live "resets in Xh Ym" countdown; the weekly window shows the
    /// concrete reset day + time, which doesn't need per-second updates.
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

    private var consentPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Experimental feature", systemImage: "exclamationmark.shield")
                .font(.callout)
                .foregroundStyle(.orange)
            Text(
                "Showing your Claude usage reuses Claude Code's login token to call an unofficial "
                    + "endpoint. This is a personal-use feature that may violate Anthropic's Terms "
                    + "of Service and could stop working without notice."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let url = URL(
                string: "https://github.com/ThugipanSivanesan/Dashi/blob/main/SECURITY.md")
            {
                Link("Learn more", destination: url).font(.caption)
            }
            Button("Enable Claude usage") {
                Task { await viewModel.grantConsent() }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
