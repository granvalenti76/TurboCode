import SwiftUI

/// Aggregates only work performed by Apple's on-device model. Delegate tools
/// may share a root run, so their backend is filtered independently.
nonisolated struct OnDeviceStatisticsSummary: Sendable {
    let runs: [AgentRunMetric]
    let compactions: [OnDeviceCompactionMetric]

    init(
        runs: [AgentRunMetric],
        compactions: [OnDeviceCompactionMetric] = []
    ) {
        self.runs = runs
        self.compactions = compactions
    }

    var requestCount: Int { runs.count }

    var successCount: Int {
        runs.count { $0.outcome == .success || $0.outcome == .successWithToolFailures }
    }

    var toolCalls: [ToolRunMetric] {
        runs.flatMap(\.tools).filter { $0.backend == ModelBackend.foundationApple.rawValue }
    }

    var errors: [OnDeviceStatisticsError] {
        let runErrors = runs.compactMap { run -> OnDeviceStatisticsError? in
            guard run.outcome == .failed else { return nil }
            return OnDeviceStatisticsError(
                id: "run-\(run.id)",
                date: run.startedAt,
                source: run.suspectedTool ?? "Session",
                category: (run.failureCategory ?? .unknown).rawValue,
                fingerprint: run.failureFingerprint
            )
        }
        let toolErrors = runs.flatMap { run in
            run.tools.compactMap { tool -> OnDeviceStatisticsError? in
                guard tool.backend == ModelBackend.foundationApple.rawValue,
                      tool.outcome == .failed else { return nil }
                return OnDeviceStatisticsError(
                    id: "tool-\(run.id)-\(tool.id)",
                    date: tool.startedAt,
                    source: tool.toolName,
                    category: (tool.failureCategory ?? .unknown).rawValue,
                    fingerprint: tool.failureFingerprint
                )
            }
        }
        return (runErrors + toolErrors).sorted { $0.date > $1.date }
    }

    /// Generation throughput excludes time to first token so prompt processing
    /// does not make the decoder appear slower than it is.
    var tokensPerSecond: Double? {
        let samples = runs.compactMap { run -> (tokens: Int, milliseconds: Int)? in
            guard let tokens = run.outputTokenCount, tokens > 0,
                  let total = run.totalMilliseconds,
                  let first = run.firstTokenMilliseconds,
                  total > first else { return nil }
            return (tokens, total - first)
        }
        let tokens = samples.reduce(0) { $0 + $1.tokens }
        let milliseconds = samples.reduce(0) { $0 + $1.milliseconds }
        guard milliseconds > 0 else { return nil }
        return Double(tokens) / (Double(milliseconds) / 1_000)
    }

    var averageFirstTokenMilliseconds: Int? {
        let values = runs.compactMap(\.firstTokenMilliseconds)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }

    var cacheHitRate: Double? {
        let input = runs.compactMap(\.inputTokenCount).reduce(0, +)
        guard input > 0 else { return nil }
        let cached = runs.compactMap(\.cachedInputTokenCount).reduce(0, +)
        return Double(cached) / Double(input)
    }

    var latestContext: (used: Int, size: Int)? {
        runs.lazy.compactMap { run in
            guard let used = run.contextTokenCount, let size = run.contextSize else { return nil }
            return (used, size)
        }.first
    }

    var toolsByName: [(name: String, calls: Int, failures: Int)] {
        Dictionary(grouping: toolCalls, by: \.toolName)
            .map { name, calls in
                (name, calls.count, calls.count { $0.outcome == .failed })
            }
            .sorted { lhs, rhs in
                lhs.calls == rhs.calls ? lhs.name < rhs.name : lhs.calls > rhs.calls
            }
    }
}

nonisolated struct OnDeviceStatisticsError: Identifiable, Sendable {
    let id: String
    let date: Date
    let source: String
    let category: String
    let fingerprint: String?
}

/// Developer-only dashboard backed by the same persisted diagnostics used by
/// benchmark reporting. It performs no model requests of its own.
struct OnDeviceStatisticsView: View {
    @State private var runs: [AgentRunMetric] = []
    @State private var compactions: [OnDeviceCompactionMetric] = []
    @State private var isLoading = true

    private var summary: OnDeviceStatisticsSummary {
        OnDeviceStatisticsSummary(runs: runs, compactions: compactions)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header
                overview
                performance
                summarization
                toolCalls
                errors
                recentRequests
            }
            .padding(24)
        }
        .frame(minWidth: 780, minHeight: 560)
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
            Text("On-Device Statistics")
                .font(.largeTitle.bold())
            Text("Apple Foundation Model requests recorded locally by TurboCode")
                .foregroundStyle(.secondary)
        }
    }

    private var overview: some View {
        HStack(spacing: 12) {
            statisticTile("Requests", value: "\(summary.requestCount)", icon: "bubble.left.and.text.bubble.right")
            statisticTile("Successful", value: "\(summary.successCount)", icon: "checkmark.circle")
            statisticTile("Tool Calls", value: "\(summary.toolCalls.count)", icon: "wrench.and.screwdriver")
            statisticTile("Errors", value: "\(summary.errors.count)", icon: "exclamationmark.triangle")
        }
    }

    private var performance: some View {
        GroupBox("Performance") {
            Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 12) {
                GridRow {
                    metricLabel("Generation")
                    metricValue(summary.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "—")
                    metricLabel("Average TTFT")
                    metricValue(summary.averageFirstTokenMilliseconds.map { "\($0) ms" } ?? "—")
                }
                GridRow {
                    metricLabel("Prefix cache")
                    metricValue(summary.cacheHitRate.map { String(format: "%.1f%% hit", $0 * 100) } ?? "—")
                    metricLabel("Current context")
                    metricValue(contextDescription)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    private var toolCalls: some View {
        GroupBox("Tool Calls") {
            if summary.toolsByName.isEmpty {
                emptyState("No on-device tool calls recorded.", icon: "wrench.and.screwdriver")
            } else {
                VStack(spacing: 0) {
                    ForEach(summary.toolsByName, id: \.name) { tool in
                        HStack {
                            Text(tool.name).font(.system(.body, design: .monospaced))
                            Spacer()
                            Text("\(tool.calls) calls")
                            if tool.failures > 0 {
                                Text("\(tool.failures) failed").foregroundStyle(.red)
                            }
                        }
                        .padding(.vertical, 7)
                        if tool.name != summary.toolsByName.last?.name { Divider() }
                    }
                }
            }
        }
    }

    private var summarization: some View {
        DisclosureGroup {
            if summary.compactions.isEmpty {
                emptyState("No context summarization recorded.", icon: "text.badge.xmark")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(summary.compactions.prefix(20)) { compaction in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Context summarized")
                                Text("\(compaction.turnCount) turns → \(compaction.retainedCharacters) characters retained")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(compaction.createdAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 7)
                        if compaction.id != summary.compactions.prefix(20).last?.id {
                            Divider()
                        }
                    }
                }
            }
        } label: {
            Label(
                "Context Summarization (\(summary.compactions.count))",
                systemImage: "text.badge.checkmark"
            )
        }
        .padding(.horizontal, 4)
    }

    private var errors: some View {
        GroupBox("Errors") {
            if summary.errors.isEmpty {
                emptyState("No on-device errors recorded.", icon: "checkmark.circle")
            } else {
                VStack(spacing: 0) {
                    ForEach(summary.errors.prefix(30)) { error in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(error.source) · \(error.category)")
                                if let fingerprint = error.fingerprint {
                                    Text("Fingerprint \(fingerprint)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(error.date, style: .relative).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 7)
                        Divider()
                    }
                }
            }
        }
    }

    private var recentRequests: some View {
        GroupBox("Recent Requests") {
            if runs.isEmpty {
                emptyState("Use the on-device model to begin collecting statistics.", icon: "chart.bar")
            } else {
                VStack(spacing: 0) {
                    ForEach(runs.prefix(50), id: \.id) { run in
                        requestRow(run)
                        Divider()
                    }
                }
            }
        }
    }

    private func requestRow(_ run: AgentRunMetric) -> some View {
        HStack(spacing: 14) {
            Image(systemName: outcomeIcon(run.outcome))
                .foregroundStyle(outcomeColor(run.outcome))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.mode.capitalized)
                Text(run.startedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            compactMetric("Input", run.inputTokenCount.map(String.init) ?? "—")
            compactMetric("Cached", run.cachedInputTokenCount.map(String.init) ?? "—")
            compactMetric("Output", run.outputTokenCount.map(String.init) ?? "—")
            compactMetric("Tools", "\(run.tools.count { $0.backend == ModelBackend.foundationApple.rawValue })")
        }
        .padding(.vertical, 8)
    }

    private func statisticTile(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.title2.bold())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
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
        .frame(minWidth: 54, alignment: .trailing)
    }

    private func emptyState(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }

    private var contextDescription: String {
        guard let context = summary.latestContext else { return "— / 8,192" }
        let remaining = max(0, context.size - context.used)
        return "\(context.used) / \(context.size) (\(remaining) left)"
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
        case nil: .blue
        }
    }

    private func reload() async {
        isLoading = true
        runs = await AgentDiagnosticsRecorder.shared.onDeviceRuns()
        compactions = await AgentDiagnosticsRecorder.shared.onDeviceCompactions()
        isLoading = false
    }
}
