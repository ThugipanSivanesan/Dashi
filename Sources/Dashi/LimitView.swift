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
            windowRow(title: "5-hour", limit: limits.fiveHour, prominent: true)
            windowRow(title: "Weekly", limit: limits.sevenDay, prominent: false)
            Text("Updated \(limits.fetchedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func windowRow(title: String, limit: RollingLimit, prominent: Bool) -> some View {
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
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("resets in \(resetCountdown(to: limit.resetsAt, now: context.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
