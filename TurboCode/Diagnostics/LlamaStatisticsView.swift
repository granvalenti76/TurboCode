import SwiftUI

/// Aggregates prompt, cache, and completion usage for the local Llama profile.
/// Prompt tokens remain part of the cumulative total even when served by KV
/// cache; cache percentage is reported separately as a reuse signal.
nonisolated struct LlamaStatisticsSummary: Sendable {
    let runs: [AgentRunMetric]

    var requestCount: Int { runs.count }

    var promptTokens: Int {
        runs.compactMap(\.inputTokenCount).reduce(0, +)
    }

    var cachedTokens: Int {
        runs.compactMap(\.cachedInputTokenCount).reduce(0, +)
    }

    var outputTokens: Int {
        runs.compactMap(\.outputTokenCount).reduce(0, +)
    }

    /// Counts all prompt and response tokens, including prompt tokens served
    /// from cache, so the value reflects total context traffic over time.
    var cumulativeTokens: Int {
        promptTokens + outputTokens
    }

    var cacheHitRate: Double? {
        guard promptTokens > 0 else { return nil }
        return Double(cachedTokens) / Double(promptTokens)
    }

    var latestContext: (used: Int, size: Int)? {
        runs.lazy.compactMap { run in
            guard let used = run.contextTokenCount,
                  let size = run.contextSize else { return nil }
            return (used, size)
        }.first
    }

    var latestRun: AgentRunMetric? { runs.first }
}

/// Developer-only dashboard for the local Llama profile. It reads persisted
/// diagnostics and never creates a model request or changes runtime state.
struct LlamaStatisticsView: View {
    @State private var runs: [AgentRunMetric] = []
    @State private var isLoading = true

    private var summary: LlamaStatisticsSummary {
        LlamaStatisticsSummary(runs: runs)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                overview
                latestTurn
                recentRuns
            }
            .padding(24)
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await reload() }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Llama Statistics")
                .font(.largeTitle.bold())
            Text("Runtime context, KV-cache reuse, and cumulative token traffic")
                .foregroundStyle(.secondary)
        }
    }

    private var overview: some View {
        let context = summary.latestContext
        return Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 14) {
            GridRow {
                metricLabel("Runtime context")
                metricValue(context.map { format($0.size) } ?? "—")
                metricLabel("Latest used")
                metricValue(context.map { "\(format($0.used)) / \(format($0.size))" } ?? "—")
            }
            GridRow {
                metricLabel("Cache used")
                metricValue(summary.cacheHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                metricLabel("Cumulative tokens")
                metricValue(format(summary.cumulativeTokens))
            }
            GridRow {
                metricLabel("Prompt tokens")
                metricValue(format(summary.promptTokens))
                metricLabel("Response tokens")
                metricValue(format(summary.outputTokens))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }

    private var latestTurn: some View {
        GroupBox("Latest turn") {
            if let run = summary.latestRun {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                    GridRow {
                        metricLabel("Prompt")
                        metricValue(run.inputTokenCount.map(format) ?? "—")
                        metricLabel("Cached")
                        metricValue(run.cachedInputTokenCount.map(format) ?? "—")
                    }
                    GridRow {
                        metricLabel("Response")
                        metricValue(run.outputTokenCount.map(format) ?? "—")
                        metricLabel("First token")
                        metricValue(run.firstTokenMilliseconds.map { "\($0) ms" } ?? "—")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else {
                Text("No Llama requests recorded yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recentRuns: some View {
        GroupBox("Recent requests (\(summary.requestCount))") {
            if runs.isEmpty {
                Text("Use the Llama profile to begin collecting statistics.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(runs.prefix(30), id: \.id) { run in
                        HStack(spacing: 14) {
                            Image(systemName: outcomeIcon(run.outcome))
                                .foregroundStyle(outcomeColor(run.outcome))
                            Text(run.startedAt, style: .date)
                                .font(.caption)
                            Spacer()
                            compactMetric("Prompt", run.inputTokenCount.map(format) ?? "—")
                            compactMetric("Cached", run.cachedInputTokenCount.map(format) ?? "—")
                            compactMetric("Output", run.outputTokenCount.map(format) ?? "—")
                        }
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            }
        }
    }

    private func reload() async {
        isLoading = true
        runs = await AgentDiagnosticsRecorder.shared.llamaRuns()
        isLoading = false
    }

    private func format(_ value: Int) -> String {
        value.formatted(.number)
    }

    private func metricLabel(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private func metricValue(_ text: String) -> some View {
        Text(text).font(.system(.body, design: .monospaced))
    }

    private func compactMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(.system(.body, design: .monospaced))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 60, alignment: .trailing)
    }

    private func outcomeIcon(_ outcome: AgentRunOutcome?) -> String {
        switch outcome {
        case .success: "checkmark.circle.fill"
        case .successWithToolFailures: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        case nil: "clock.fill"
        }
    }

    private func outcomeColor(_ outcome: AgentRunOutcome?) -> Color {
        switch outcome {
        case .success: .green
        case .successWithToolFailures: .orange
        case .failed: .red
        case .cancelled: .secondary
        case nil: .secondary
        }
    }
}
