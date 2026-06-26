import AppKit
import DashiCore
import SwiftUI

/// The popup shown from the menu bar. Renders the ``UsageViewModel`` state and refreshes on appear.
struct UsageView: View {
    @State private var viewModel: UsageViewModel

    init(provider: any UsageProvider) {
        _viewModel = State(wrappedValue: UsageViewModel(provider: provider))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Dashi").font(.headline)
                Spacer()
                Text("Today").foregroundStyle(.secondary).font(.caption)
            }

            content

            Divider()
            Button("Quit Dashi") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 280)
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, alignment: .center)
        case .loaded(let summary):
            summaryView(summary)
        case .empty:
            Text("No usage recorded today.").foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private func summaryView(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(summary.providers) { usage in
                HStack {
                    Text(usage.provider.displayName)
                    Spacer()
                    Text("\(usage.totalTokens) tok").monospacedDigit()
                }
                .font(.callout)
            }
            Divider()
            HStack {
                Text("Total").bold()
                Spacer()
                Text("\(summary.totalTokens) tok").bold().monospacedDigit()
            }
            HStack {
                Text("Est. cost").foregroundStyle(.secondary)
                Spacer()
                Text(summary.totalCostUSD, format: .currency(code: "USD"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
