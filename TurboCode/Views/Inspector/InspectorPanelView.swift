import AppKit
import SwiftUI

// MARK: - Inspector Panel

struct InspectorPanelView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        Group {
            if chatStore.rightPanelMode == .activity {
                if !chatStore.agentActivities.isEmpty {
                    AgentActivityCollectionView(
                        activities: chatStore.agentActivities,
                        selected: chatStore.currentAgentActivity
                    )
                } else {
                    DelegatedActivityEmptyStateView()
                }
            } else if chatStore.rightPanelMode == .workspaceListing,
               let listing = chatStore.inspectedWorkspaceListing {
                WorkspaceListingInspectorView(listing: listing)
            } else if chatStore.rightPanelMode == .commit,
               let receipt = chatStore.inspectedGitCommit {
                GitCommitInspectorView(receipt: receipt)
            } else if chatStore.isLoadingDiffs {
                stateView(icon: nil, title: "Loading changes", subtitle: nil, showsProgress: true)
            } else if let error = chatStore.diffLoadError {
                stateView(
                    icon: "exclamationmark.triangle",
                    title: "Changes unavailable",
                    subtitle: error
                )
            } else if chatStore.diffSections.isEmpty {
                stateView(
                    icon: "checkmark.circle",
                    title: "No changes",
                    subtitle: "The working tree is clean"
                )
            } else {
                FileInspectorView(sections: chatStore.diffSections)
            }
        }
        .background(.background)
    }

    private func stateView(
        icon: String?,
        title: String,
        subtitle: String?,
        showsProgress: Bool = false
    ) -> some View {
        VStack(spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            if let subtitle {
                Text(subtitle)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 240)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// Keeps the persistent delegated-activity entry point useful between runs
/// without inventing historical task data that the current store does not own.
private struct DelegatedActivityEmptyStateView: View {
    var body: some View {
        ContentUnavailableView(
            "No delegated task",
            systemImage: "person.2",
            description: Text(
                "Activity from a delegated subagent will appear here when a task is running."
            )
        )
    }
}

// MARK: - Agent Activity Inspector

/// Derives compact inspector copy without changing or re-summarizing the
/// structured task sent to the worker.
nonisolated struct AgentTaskPresentation: Equatable, Sendable {
    let summary: String
    let fullText: String
    let showsFullTaskDisclosure: Bool

    init(goal: String, summaryLimit: Int = 220) {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        // Preserve the exact source text for disclosure and selection; trimming
        // is applied only to the compact presentation derived below.
        fullText = goal

        let normalizedNewlines = trimmed.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedNewlines.components(separatedBy: "\n")
        let isLong = trimmed.count > 320 || lines.count > 8
        guard isLong else {
            summary = trimmed
            showsFullTaskDisclosure = false
            return
        }

        // Coordinator prompts conventionally place the human-scale objective
        // before detailed steps or code. Prefer that paragraph, then cap it at
        // a word boundary so Activity remains useful at narrow inspector widths.
        let firstParagraph = normalizedNewlines
            .components(separatedBy: "\n\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? normalizedNewlines
        let compact = firstParagraph
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        summary = Self.truncated(compact, limit: summaryLimit)
        showsFullTaskDisclosure = true
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = String(text.prefix(limit))
        if let boundary = prefix.lastIndex(of: " "),
           prefix.distance(from: prefix.startIndex, to: boundary) > limit / 2 {
            return String(prefix[..<boundary]) + "…"
        }
        return prefix + "…"
    }
}

/// Converts provider-facing result text into a user-facing Activity summary.
/// Raw JSON remains available for diagnosis but never leads the completed view.
nonisolated struct AgentResultAction: Equatable, Sendable, Identifiable {
    let tool: String
    let operation: String
    let detail: String?

    var id: String { "\(tool)|\(operation)|\(detail ?? "")" }
}

nonisolated struct AgentResultPresentation: Equatable, Sendable {
    let summary: String
    let actions: [AgentResultAction]
    let technicalDetails: String?

    init(result: AgentTaskResult) {
        let raw = result.technicalSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let protocolActions = Self.protocolActions(from: raw)
        if !protocolActions.isEmpty {
            summary = protocolActions.count == 1
                ? "The worker reported one tool action."
                : "The worker reported \(protocolActions.count) tool actions."
            actions = protocolActions
            technicalDetails = result.technicalSummary
        } else if Self.containsProtocolArtifacts(raw) {
            // Never promote opaque provider control tokens to user-facing copy,
            // even when a future provider format cannot yet be decomposed.
            summary = Self.fallbackSummary(for: result.outcome)
            actions = []
            technicalDetails = result.technicalSummary
        } else if let object = Self.jsonObject(from: raw) {
            summary = Self.preferredString(in: object)
                ?? Self.fallbackSummary(for: result.outcome)
            actions = []
            technicalDetails = result.technicalSummary
        } else if raw.count > 600 {
            summary = AgentTaskPresentation(goal: raw).summary
            actions = []
            technicalDetails = result.technicalSummary
        } else {
            summary = raw
            actions = []
            technicalDetails = nil
        }
    }

    private static func containsProtocolArtifacts(_ text: String) -> Bool {
        text.contains("<ctrl") || text.contains("call:default_api:")
    }

    private static func protocolActions(from text: String) -> [AgentResultAction] {
        guard containsProtocolArtifacts(text) else { return [] }
        return text
            .components(separatedBy: "call:default_api:")
            .dropFirst()
            .compactMap { segment in
                guard let openingBrace = segment.firstIndex(of: "{") else {
                    return nil
                }
                let tool = String(segment[..<openingBrace])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tool.isEmpty else { return nil }
                let arguments = String(segment[segment.index(after: openingBrace)...])
                let operation = controlTokenValue(
                    named: "operation",
                    in: arguments
                ) ?? "Run"
                let paths = controlTokenValues(inArrayNamed: "paths", in: arguments)
                return AgentResultAction(
                    tool: tool,
                    operation: operation,
                    detail: paths.isEmpty ? nil : paths.joined(separator: ", ")
                )
            }
    }

    private static func controlTokenValue(
        named name: String,
        in text: String
    ) -> String? {
        guard let field = text.range(of: "\(name):<ctrl") else { return nil }
        let suffix = text[field.upperBound...]
        guard let tokenEnd = suffix.firstIndex(of: ">") else { return nil }
        let valueStart = suffix.index(after: tokenEnd)
        guard let valueEnd = suffix[valueStart...].range(of: "<ctrl")?.lowerBound else {
            return nil
        }
        let value = suffix[valueStart..<valueEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func controlTokenValues(
        inArrayNamed name: String,
        in text: String
    ) -> [String] {
        guard let field = text.range(of: "\(name):[") else { return [] }
        let suffix = text[field.upperBound...]
        guard let closingBracket = suffix.firstIndex(of: "]") else { return [] }
        let array = String(suffix[..<closingBracket])
        guard let expression = try? NSRegularExpression(
            pattern: #"<ctrl\d+>([^<]*)<ctrl\d+>"#
        ) else {
            return []
        }
        let range = NSRange(array.startIndex..<array.endIndex, in: array)
        return expression.matches(in: array, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: array) else {
                return nil
            }
            let value = array[valueRange]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    private static func jsonObject(from text: String) -> Any? {
        var candidate = text
        if candidate.hasPrefix("```") {
            let lines = candidate.components(separatedBy: .newlines)
            candidate = lines.dropFirst().joined(separator: "\n")
            if candidate.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("```"),
               let fence = candidate.range(of: "```", options: .backwards) {
                candidate.removeSubrange(fence.lowerBound..<candidate.endIndex)
            }
        }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = candidate.firstIndex(of: "{"),
              let last = candidate.lastIndex(of: "}"),
              first <= last,
              let data = String(candidate[first...last]).data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func preferredString(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            // Result containers take precedence over echoed task metadata such
            // as goal or acceptance criteria.
            for key in ["result", "output", "data"] {
                if let value = dictionary[key],
                   let text = preferredString(in: value) {
                    return text
                }
            }
            for key in ["technicalSummary", "summary", "message", "stdout"] {
                if let text = dictionary[key] as? String,
                   let readable = readableString(text) {
                    return readable
                }
            }
            for value in dictionary.values {
                if value is [String: Any] || value is [Any],
                   let text = preferredString(in: value) {
                    return text
                }
            }
        } else if let values = object as? [Any] {
            for value in values {
                if let text = preferredString(in: value) {
                    return text
                }
            }
        } else if let text = object as? String {
            return readableString(text)
        }
        return nil
    }

    private static func readableString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("{"),
              !trimmed.hasPrefix("[") else {
            return nil
        }
        return trimmed
    }

    private static func fallbackSummary(for outcome: AgentTaskOutcome) -> String {
        switch outcome {
        case .completed: "The worker completed the delegated task."
        case .verified: "The delegated task completed and verification passed."
        case .cancelled: "The delegated task was cancelled."
        case .failed: "The delegated task failed."
        }
    }
}

/// The one safe next step offered after an unsuccessful delegated attempt.
///
/// Recovery stays intentionally narrow for 0.2.0: an action either opens an
/// immutable receipt or prepares a draft for the user to review. It never
/// retries, rolls back, or starts another model request on its own.
nonisolated enum AgentRecoveryAction: Equatable, Sendable {
    case prepareRetry
    case prepareReread
    case reviewChanges(receiptID: String)
    case runCoordinator

    var requiresComposer: Bool {
        switch self {
        case .prepareRetry, .prepareReread, .runCoordinator:
            true
        case .reviewChanges:
            false
        }
    }
}

/// Maps machine-readable failure reasons to one human-scale recovery action.
///
/// Keeping this mapping outside the view makes the "one valid action" rule
/// deterministic and prevents provider prose from choosing UI behavior.
nonisolated struct AgentRecoveryPresentation: Equatable, Sendable {
    let action: AgentRecoveryAction
    let title: String
    let guidance: String
    let symbolName: String

    init?(
        result: AgentTaskResult,
        reviewableReceiptID: String?
    ) {
        guard result.outcome == .failed || result.outcome == .cancelled,
              let failureReason = result.failureReason else {
            return nil
        }

        switch failureReason {
        case .revisionConflict:
            action = .prepareReread
            title = "Prepare New Reading"
            guidance = "Re-read the latest file before proposing another edit."
            symbolName = "arrow.clockwise"
        case .verificationFailed, .verificationInvalidated:
            if let reviewableReceiptID {
                action = .reviewChanges(receiptID: reviewableReceiptID)
                title = "Review Changes"
                guidance = "Inspect the recorded changes before deciding what to run again."
                symbolName = "doc.text.magnifyingglass"
            } else {
                action = .runCoordinator
                title = "Continue in Coordinator"
                guidance = "Let the coordinator inspect the current workspace and choose the next check."
                symbolName = "brain.head.profile"
            }
        case .toolNotAllowed, .pathOutsideScope:
            action = .runCoordinator
            title = "Continue in Coordinator"
            guidance = "Review the task scope directly before attempting another delegation."
            symbolName = "brain.head.profile"
        case .workerFailed, .timedOut, .toolLimitReached, .invalidResult, .cancelled:
            action = .prepareRetry
            title = "Prepare New Attempt"
            guidance = "Create a fresh attempt after reviewing the current workspace state."
            symbolName = "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }

    /// Builds a user-reviewable recovery prompt with an explicit fresh attempt
    /// identity. The coordinator must inspect current state rather than reuse
    /// file revisions or assumptions from the failed attempt.
    func draft(for activity: AgentActivity, newAttemptID: String) -> String? {
        let context = """
        Task ID: \(activity.taskID)
        New attempt ID: \(newAttemptID)
        Original goal: \(activity.goal)
        """
        switch action {
        case .prepareRetry:
            return """
            Prepare a new delegated attempt for this task.

            \(context)

            Reassess the current workspace first. Do not reuse file revisions, \
            tool assumptions, or verification evidence from the previous attempt. \
            Show me the plan in the composer before starting the delegation.
            """
        case .prepareReread:
            return """
            Recover from the revision conflict for this task.

            \(context)

            Re-read the affected file from the current workspace before proposing \
            or delegating any edit. Do not reuse the previous revision hash. Show \
            me the recovery request in the composer before starting it.
            """
        case .runCoordinator:
            return """
            Continue this task directly in the coordinator without delegating \
            another worker yet.

            \(context)

            Inspect the current workspace and the previous failure, then propose \
            the smallest safe next action. Do not reuse stale file revisions or \
            previous verification evidence.
            """
        case .reviewChanges:
            return nil
        }
    }
}

/// Native, conversation-local presentation of one structured delegation.
///
/// The route renders only reducer state and typed results. It deliberately has
/// no percentage progress or model transcript because neither is authoritative.
private struct AgentActivityCollectionView: View {
    let activities: [AgentActivity]
    let selected: AgentActivity?

    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        VStack(spacing: 0) {
            if activities.count > 1 {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Tasks")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(runningCount) running")
                            .font(AppTypography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 7) {
                            ForEach(activities) { activity in
                                Button {
                                    chatStore.selectAgentActivity(activity.id)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: activity.phase.symbolName)
                                            .foregroundStyle(activity.phase.tint)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(activity.worker.modelName)
                                                .font(.system(size: 11.5, weight: .medium))
                                            Text(activity.phase.displayName)
                                                .font(AppTypography.metadata)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 7)
                                    .background(
                                        activity.id == selected?.id
                                            ? Color.accentColor.opacity(0.16)
                                            : Color.secondary.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(10)
                Divider()
            }

            if let selected {
                AgentActivityInspectorView(activity: selected)
            }
        }
    }

    private var runningCount: Int {
        activities.count(where: { !$0.phase.isTerminal })
    }
}

private struct AgentActivityInspectorView: View {
    let activity: AgentActivity

    @Environment(ChatStore.self) private var chatStore
    @Environment(ComposerViewModel.self) private var composer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fullTaskPresented = false
    @State private var technicalResultPresented = false
    @State private var verificationDetailsPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    taskSection
                    routeSection

                    if let activeTool = activity.activeTool {
                        activeToolSection(activeTool)
                    }
                    if let result = activity.finalResult {
                        resultSection(result)
                    }
                }
                .padding(16)
                // Native controls remain in visual/source order: task
                // disclosure, receipt actions, then technical disclosure.
                // A focus section supports keyboard traversal without moving
                // focus away from the composer when Activity first appears.
                .focusSection()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: activity.phase
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: activity.phase.symbolName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(activity.phase.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Activity")
                    .font(.system(size: 15, weight: .semibold))

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(
                        "\(activity.phase.displayName) · \(elapsedText(at: context.date))"
                    )
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if !activity.phase.isTerminal {
                Button {
                    Task { await chatStore.cancelAgentActivity(activity) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .keyboardShortcut(.cancelAction)
                .help("Stop delegated task")
                .accessibilityLabel("Stop delegated task")
            }

            Button {
                chatStore.closeRightPanel()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close Activity inspector")
            .accessibilityLabel("Close Activity inspector")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 52)
        .focusSection()
    }

    private var taskSection: some View {
        let presentation = AgentTaskPresentation(goal: activity.goal)
        return VStack(alignment: .leading, spacing: 7) {
            Text("Task")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text(presentation.summary)
                .font(.system(size: 13))
                .textSelection(.enabled)

            if presentation.showsFullTaskDisclosure {
                DisclosureGroup(
                    isExpanded: $fullTaskPresented
                ) {
                    Text(presentation.fullText)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            Color(nsColor: .textBackgroundColor).opacity(0.55),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .padding(.top, 5)
                } label: {
                    Text("Full Task")
                        .font(.system(size: 12, weight: .medium))
                }
                .transaction { transaction in
                    // Native disclosure remains keyboard accessible while
                    // honoring the system preference for reduced motion.
                    if reduceMotion {
                        transaction.animation = nil
                    }
                }
            }

            Text("Attempt \(activity.attemptID)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var routeSection: some View {
        GroupBox {
            VStack(spacing: 0) {
                routeRow(
                    title: "Coordinator",
                    model: activity.coordinator.modelName,
                    symbol: "brain.head.profile",
                    status: routeStatus(for: .coordinator)
                )
                routeConnector
                routeRow(
                    title: "Worker",
                    model: activity.worker.modelName,
                    symbol: "hammer",
                    status: routeStatus(for: .worker)
                )
                routeConnector
                routeRow(
                    title: "Verification",
                    model: verificationDetail,
                    symbol: "checkmark.seal",
                    status: routeStatus(for: .verification)
                )
            }
            .padding(.vertical, 4)
        } label: {
            Label("Agent Route", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private func routeRow(
        title: String,
        model: String,
        symbol: String,
        status: AgentRouteStatus
    ) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(status.tint.opacity(0.12))
                Image(systemName: status.symbolName ?? symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(status.tint)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                Text(model)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(status.label)
                .font(AppTypography.badge)
                .foregroundStyle(status.tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(model), \(status.label)")
    }

    private var routeConnector: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14.5)
            .accessibilityHidden(true)
    }

    private func activeToolSection(
        _ tool: AgentActivityTool
    ) -> some View {
        GroupBox {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 12.5, weight: .medium))
                    Text(tool.owner == .coordinator ? "Coordinator tool" : "Worker tool")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // A textual state avoids implying measurable progress and
                // keeps movement limited to actual phase transitions.
                Text("Running")
                    .font(AppTypography.badge)
                    .foregroundStyle(Color.accentColor)
            }
        } label: {
            Text("Current Tool")
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private func resultSection(_ result: AgentTaskResult) -> some View {
        let presentation = AgentResultPresentation(result: result)
        let shortcutReceiptID = result.receiptIDs.first {
            chatStore.canOpenActivityReceipt($0)
        }
        let recovery = AgentRecoveryPresentation(
            result: result,
            reviewableReceiptID: shortcutReceiptID
        )
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: result.outcome.symbolName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(result.outcome.tint)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.outcome.displayName)
                            .font(.system(size: 13, weight: .semibold))
                        Text(presentation.summary)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)

                if !presentation.actions.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(presentation.actions) { action in
                            HStack(spacing: 9) {
                                Image(systemName: action.tool == "git"
                                      ? "arrow.triangle.branch"
                                      : "wrench.and.screwdriver")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(actionTitle(action))
                                        .font(.system(size: 11.5, weight: .medium))
                                    if let detail = action.detail {
                                        Text(detail)
                                            .font(AppTypography.metadata)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.green)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(
                                Color.secondary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                if let detail = result.failureDetail, !detail.isEmpty {
                    Label(detail, systemImage: "exclamationmark.triangle")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                }

                if result.verification.status != .notRequested {
                    Divider()
                    verificationEvidence(result.verification)
                    if let detail = result.verification.detail,
                       verificationHasExtendedDetail(detail) {
                        DisclosureGroup(
                            isExpanded: $verificationDetailsPresented
                        ) {
                            Text(detail)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    Color(nsColor: .textBackgroundColor).opacity(0.55),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .padding(.top, 5)
                        } label: {
                            Text("Verification Details")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .transaction { transaction in
                            if reduceMotion {
                                transaction.animation = nil
                            }
                        }
                    }
                }

                if !result.unresolvedWork.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Remaining Work", systemImage: "list.bullet.clipboard")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(result.unresolvedWork, id: \.self) { item in
                            Label(item, systemImage: "circle")
                                .font(AppTypography.metadata)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let recovery {
                    Divider()
                    recoverySection(recovery)
                }

                if !result.receiptIDs.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Receipts")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        ForEach(result.receiptIDs, id: \.self) { receiptID in
                            if receiptID == shortcutReceiptID {
                                receiptButton(receiptID, showsShortcut: true)
                                    .keyboardShortcut(
                                        "r",
                                        modifiers: [.command, .shift]
                                    )
                            } else {
                                receiptButton(receiptID, showsShortcut: false)
                            }
                        }
                    }
                }

                if let technicalDetails = presentation.technicalDetails {
                    Divider()
                    DisclosureGroup(
                        isExpanded: $technicalResultPresented
                    ) {
                        Text(technicalDetails)
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                Color(nsColor: .textBackgroundColor).opacity(0.55),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .padding(.top, 5)
                    } label: {
                        Text("Technical Details")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .transaction { transaction in
                        if reduceMotion {
                            transaction.animation = nil
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Result", systemImage: "checklist")
                .font(.system(size: 12, weight: .semibold))
        }
    }

    /// Presents one primary recovery action using native button semantics.
    /// Draft-producing actions are disabled while the composer contains user
    /// text so recovery can never overwrite unrelated work.
    private func recoverySection(
        _ recovery: AgentRecoveryPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Next Step", systemImage: "arrow.right.circle")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(recovery.guidance)
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)

            Button {
                performRecovery(recovery)
            } label: {
                Label(recovery.title, systemImage: recovery.symbolName)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(
                recovery.action.requiresComposer
                    && !composer.messageText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
            )
            .help(recoveryHelp(recovery))
        }
    }

    private func performRecovery(_ recovery: AgentRecoveryPresentation) {
        switch recovery.action {
        case .reviewChanges(let receiptID):
            chatStore.openActivityReceipt(receiptID)
        case .prepareRetry, .prepareReread, .runCoordinator:
            guard composer.messageText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else {
                return
            }
            let attemptID = "attempt-\(UUID().uuidString.lowercased())"
            guard let draft = recovery.draft(
                for: activity,
                newAttemptID: attemptID
            ) else {
                return
            }
            // Closing the inspector reveals the focused composer containing
            // the draft; sending remains an explicit user action.
            composer.messageText = draft
            chatStore.closeRightPanel()
        }
    }

    private func recoveryHelp(_ recovery: AgentRecoveryPresentation) -> String {
        if recovery.action.requiresComposer,
           !composer.messageText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty {
            return "Send or clear the current draft before preparing recovery"
        }
        return recovery.guidance
    }

    private func receiptButton(
        _ receiptID: String,
        showsShortcut: Bool
    ) -> some View {
        let isAvailable = chatStore.canOpenActivityReceipt(receiptID)
        return Button {
            chatStore.openActivityReceipt(receiptID)
        } label: {
            Label(
                receiptID,
                systemImage: "doc.text.magnifyingglass"
            )
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .disabled(!isAvailable)
        .help(
            isAvailable
                ? (
                    showsShortcut
                        ? "Open receipt in inspector (⇧⌘R)"
                        : "Open receipt in inspector"
                )
                : "Receipt is not available in this conversation"
        )
        .accessibilityLabel(
            isAvailable
                ? "Open receipt \(receiptID)"
                : "Receipt \(receiptID) is unavailable"
        )
    }

    private func actionTitle(_ action: AgentResultAction) -> String {
        let tool = action.tool
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        let operation = action.operation
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        return "\(tool) · \(operation)"
    }

    private func verificationEvidence(
        _ verification: AgentVerificationResult
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: verification.status.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(verification.status.tint)
                .frame(width: 22, height: 22)
                .background(
                    verification.status.tint.opacity(0.10),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.verificationRequest == .test ? "Tests" : "Build")
                    .font(.system(size: 11.5, weight: .semibold))
                if let detail = verification.detail,
                   let summary = verificationSummary(detail) {
                    Text(summary)
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Text(verification.status.displayName)
                .font(AppTypography.badge)
                .foregroundStyle(verification.status.tint)
        }
        .padding(9)
        .background(
            verification.status.tint.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(activity.verificationRequest == .test ? "Tests" : "Build"), "
                + verification.status.displayName
        )
    }

    private func verificationSummary(_ detail: String) -> String? {
        detail.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map {
                $0.replacingOccurrences(of: "XCODE ", with: "")
                    .replacingOccurrences(of: "_", with: " ")
                    .capitalized
            }
    }

    private func verificationHasExtendedDetail(_ detail: String) -> Bool {
        detail.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count > 1
    }

    private func resultMetadataRow(
        title: String,
        value: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
            Spacer()
            Text(value)
                .font(AppTypography.badge)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private enum RouteStep: Int {
        case coordinator
        case worker
        case verification
    }

    private func routeStatus(for step: RouteStep) -> AgentRouteStatus {
        if step == .verification {
            return verificationRouteStatus
        }

        let activeStep: RouteStep = switch activity.lastOperationalPhase {
        case .preparing, .delegating:
            .coordinator
        case .workerRunning:
            .worker
        case .verifying:
            .verification
        case .succeeded, .failed, .cancelled:
            .worker
        }
        if step.rawValue < activeStep.rawValue {
            return .completed
        }
        if step.rawValue > activeStep.rawValue {
            return .pending
        }
        guard activity.phase.isTerminal else { return .active }
        return terminalRouteStatus
    }

    private var verificationRouteStatus: AgentRouteStatus {
        guard activity.verificationRequest != .none else {
            return .notRequested
        }
        if activity.lastOperationalPhase == .verifying {
            return activity.phase.isTerminal ? terminalRouteStatus : .active
        }
        switch activity.finalResult?.verification.status {
        case .passed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        case .notRequested, nil:
            return .requested
        }
    }

    private var terminalRouteStatus: AgentRouteStatus {
        switch activity.phase {
        case .succeeded: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        case .preparing, .delegating, .workerRunning, .verifying: .active
        }
    }

    private var verificationDetail: String {
        switch activity.verificationRequest {
        case .none: "Not requested"
        case .build: "Build requested"
        case .test: "Tests requested"
        }
    }

    private func elapsedText(at date: Date) -> String {
        let end = activity.completedAt ?? date
        let seconds = max(0, Int(end.timeIntervalSince(activity.startedAt)))
        if seconds >= 3_600 {
            return String(
                format: "%d:%02d:%02d",
                seconds / 3_600,
                (seconds % 3_600) / 60,
                seconds % 60
            )
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private enum AgentRouteStatus {
    case pending
    case active
    case completed
    case requested
    case notRequested
    case failed
    case cancelled

    var label: String {
        switch self {
        case .pending: "Pending"
        case .active: "Active"
        case .completed: "Completed"
        case .requested: "Requested"
        case .notRequested: "Not requested"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var symbolName: String? {
        switch self {
        case .completed: "checkmark"
        case .failed: "xmark"
        case .cancelled: "stop.fill"
        case .pending, .active, .requested, .notRequested: nil
        }
    }

    var tint: Color {
        switch self {
        case .active: .accentColor
        case .completed: .green
        case .failed: .red
        case .cancelled: .orange
        case .requested: .blue
        case .pending, .notRequested: .secondary
        }
    }
}

private extension AgentActivityPhase {
    var displayName: String {
        switch self {
        case .preparing: "Preparing"
        case .delegating: "Delegating"
        case .workerRunning: "Worker running"
        case .verifying: "Verifying"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var symbolName: String {
        switch self {
        case .preparing: "ellipsis.circle"
        case .delegating: "arrow.right.circle"
        case .workerRunning: "hammer.circle"
        case .verifying: "checkmark.seal"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .orange
        case .preparing, .delegating, .workerRunning, .verifying: .accentColor
        }
    }
}

private extension AgentTaskOutcome {
    var displayName: String {
        switch self {
        case .completed: "Completed"
        case .verified: "Verified"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }

    var symbolName: String {
        switch self {
        case .completed: "checkmark.circle.fill"
        case .verified: "checkmark.seal.fill"
        case .cancelled: "stop.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .completed, .verified: .green
        case .cancelled: .orange
        case .failed: .red
        }
    }
}

private extension AgentVerificationStatus {
    var displayName: String {
        switch self {
        case .notRequested: "Not requested"
        case .passed: "Passed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var symbolName: String {
        switch self {
        case .notRequested: "minus.circle"
        case .passed: "checkmark.seal.fill"
        case .failed: "xmark.seal.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notRequested: .secondary
        case .passed: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }
}

// MARK: - Workspace Listing Inspector

/// Detailed view of one immutable list_workspace result. It intentionally has
/// no refresh action: a new filesystem read must create a new timeline receipt.
private struct WorkspaceListingInspectorView: View {
    let listing: WorkspaceListingBlock

    @Environment(ChatStore.self) private var chatStore
    @State private var sortOrder = [KeyPathComparator(\WorkspaceListingEntry.name)]

    private var sortedEntries: [WorkspaceListingEntry] {
        listing.entries.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let errorMessage = listing.errorMessage {
                ContentUnavailableView(
                    "Directory unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if listing.entries.isEmpty {
                ContentUnavailableView(
                    "Empty Directory",
                    systemImage: "folder",
                    description: Text("This directory contained no items in the captured snapshot.")
                )
            } else {
                Table(sortedEntries, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { entry in
                        HStack(spacing: 7) {
                            Image(systemName: iconName(for: entry))
                                .foregroundStyle(iconColor(for: entry))
                                .frame(width: 16)
                            Text(entry.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(entry.relativePath)
                        }
                    }

                    TableColumn("Modified", value: \.sortableModifiedAt) { entry in
                        Text(formattedDate(entry.modifiedAt) ?? "—")
                            .foregroundStyle(entry.modifiedAt == nil ? .tertiary : .secondary)
                    }
                    .width(min: 82, ideal: 94)

                    TableColumn("Size", value: \.sortableSizeBytes) { entry in
                        Text(formattedSize(entry.sizeBytes) ?? "—")
                            .foregroundStyle(entry.sizeBytes == nil ? .tertiary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 52, ideal: 66)
                }
                .font(.system(size: 12))
            }

            if listing.isTruncated, listing.errorMessage == nil {
                Divider()
                Label(
                    "Showing \(listing.entries.count) of \(listing.totalCount) items. List a more specific folder for a complete result.",
                    systemImage: "ellipsis.circle"
                )
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Workspace Files")
                    .font(.system(size: 15, weight: .semibold))

                HStack(spacing: 6) {
                    if let workspaceName = listing.workspaceName {
                        Text(workspaceName)
                        Text("·")
                    }
                    Text(displayPath)
                        .fontDesign(.monospaced)
                    Text("·")
                    Text(countLabel)
                    if let capturedAt = listing.capturedAt {
                        Text("·")
                        Text("Snapshot \(capturedAt.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(listing.path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy directory path")

            Button {
                chatStore.dismissWorkspaceListingInspector()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close inspector")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 52)
    }

    private var displayPath: String {
        listing.path == "." ? "Workspace Root" : listing.path
    }

    private var countLabel: String {
        "\(listing.totalCount) \(listing.totalCount == 1 ? "item" : "items")"
    }

    private func formattedDate(_ value: String?) -> String? {
        guard let value, let date = ISO8601DateFormatter().date(from: value) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func formattedSize(_ value: Int?) -> String? {
        value.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }

    private func iconName(for entry: WorkspaceListingEntry) -> String {
        switch entry.kind {
        case .directory: "folder.fill"
        case .symbolicLink: "link"
        case .file:
            switch entry.fileExtension {
            case "swift": "swift"
            case "xcodeproj", "xcworkspace": "hammer.fill"
            case "md", "txt": "doc.text.fill"
            case "json", "plist", "yaml", "yml": "curlybraces"
            case "png", "jpg", "jpeg", "heic", "svg": "photo.fill"
            default: "doc.fill"
            }
        }
    }

    private func iconColor(for entry: WorkspaceListingEntry) -> Color {
        switch entry.kind {
        case .directory: .blue
        case .symbolicLink: .purple
        case .file where entry.fileExtension == "swift": .orange
        case .file: .secondary
        }
    }
}

private extension WorkspaceListingEntry {
    /// Nonoptional presentation keys let native Table column headers provide
    /// sorting while directories continue to render blank metadata cells.
    var sortableModifiedAt: String { modifiedAt ?? "" }
    var sortableSizeBytes: Int { sizeBytes ?? -1 }
}

// MARK: - Commit Inspector

private struct GitCommitInspectorView: View {
    let receipt: GitCommitBlock

    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if receipt.files.isEmpty {
                ContentUnavailableView(
                    "No file statistics",
                    systemImage: "doc.questionmark",
                    description: Text("Git did not return numstat data for this commit.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(receipt.files) { file in
                            HStack(spacing: 9) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)

                                Text(file.path)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer(minLength: 8)

                                Text("+\(file.additions)")
                                    .foregroundStyle(.green)
                                Text("-\(file.deletions)")
                                    .foregroundStyle(.red)
                            }
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 38)

                            if file.id != receipt.files.last?.id {
                                Divider().padding(.leading, 37)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: receipt.status == .committed
                  ? "checkmark.circle.fill"
                  : "arrow.uturn.backward.circle.fill")
                .foregroundStyle(receipt.status == .committed ? Color.green : Color.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.message)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 7) {
                    Text(receipt.shortHash).fontDesign(.monospaced)
                    Text(receipt.branch)
                    Text("+\(receipt.additions)").foregroundStyle(.green)
                    Text("-\(receipt.deletions)").foregroundStyle(.red)
                }
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(receipt.hash, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy commit hash")

            Button {
                chatStore.closeRightPanel()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close inspector")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 52)
    }
}

// MARK: - File Inspector

private enum DiffContextMode: String, CaseIterable, Identifiable {
    case focused = "Focused"
    case full = "Full"

    var id: Self { self }
}

struct FileInspectorView: View {
    let sections: [FileDiffSection]
    private let gutterWidth: CGFloat
    private let minimumContentWidth: CGFloat
    private let syntaxTokensByLineID: [UUID: [InspectorSyntaxToken]]

    @Environment(ChatStore.self) private var chatStore
    @State private var collapsed: Set<String> = []
    @State private var contextMode: DiffContextMode = .focused
    @State private var editingLineID: UUID?
    @State private var showsDiscardConfirmation = false

    private var additions: Int { sections.reduce(0) { $0 + $1.added } }
    private var deletions: Int { sections.reduce(0) { $0 + $1.removed } }

    init(sections: [FileDiffSection]) {
        self.sections = sections
        // Measure the immutable Git snapshot once. Disclosure and collapse
        // state should not rescan every source line during each animation.
        let lines = sections.flatMap(\.diffLines)
        let gutterWidth = InspectorDiffLayout.gutterWidth(for: lines)
        self.gutterWidth = gutterWidth
        minimumContentWidth = InspectorDiffLayout.minimumContentWidth(
            for: lines,
            gutterWidth: gutterWidth
        )
        syntaxTokensByLineID = sections.reduce(into: [:]) { result, section in
            result.merge(
                InspectorSyntaxHighlighter.tokens(
                    for: section.diffLines,
                    filePath: section.path
                ),
                uniquingKeysWith: { _, new in new }
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()

            GeometryReader { geometry in
                let viewportWidth = geometry.size.width
                let contentWidth = max(viewportWidth, minimumContentWidth)

                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0) {
                        ForEach(sections) { section in
                            DiffSectionView(
                                section: section,
                                isCollapsed: collapsed.contains(section.id),
                                contextMode: contextMode,
                                viewportWidth: viewportWidth,
                                contentWidth: contentWidth,
                                gutterWidth: gutterWidth,
                                syntaxTokensByLineID: syntaxTokensByLineID,
                                comments: chatStore.reviewComments,
                                editingLineID: $editingLineID,
                                onToggle: { toggle(section.id) },
                                onSaveComment: saveComment,
                                onRemoveComment: removeComment
                            )

                            if section.id != sections.last?.id {
                                Divider()
                                    .frame(width: contentWidth)
                            }
                        }
                    }
                    .frame(width: contentWidth, alignment: .leading)
                }
                .scrollIndicators(.visible)
            }

            if !chatStore.reviewComments.isEmpty {
                Divider()
                reviewBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            "Discard all review comments?",
            isPresented: $showsDiscardConfirmation
        ) {
            Button("Discard Comments", role: .destructive) {
                editingLineID = nil
                chatStore.discardReviewComments()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These comments have not been sent to the model.")
        }
        .onChange(of: sections.flatMap(\.diffLines).map(\.id)) { _, visibleIDs in
            guard let editingLineID, !visibleIDs.contains(editingLineID) else { return }
            self.editingLineID = nil
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Changes")
                    .font(.system(size: 15, weight: .semibold))

                HStack(spacing: 7) {
                    Text("\(sections.count) \(sections.count == 1 ? "file" : "files")")
                        .foregroundStyle(.secondary)
                    Text("+\(additions)")
                        .foregroundStyle(.green)
                    Text("-\(deletions)")
                        .foregroundStyle(.red)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }

            Spacer(minLength: 8)

            Menu {
                Picker("Context", selection: $contextMode) {
                    ForEach(DiffContextMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            } label: {
                Image(systemName: contextMode == .focused
                      ? "line.3.horizontal.decrease"
                      : "text.alignleft")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Context: \(contextMode.rawValue)")

            Button {
                Task { await chatStore.reloadDiffs() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh changes")

            Button {
                chatStore.closeRightPanel()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close inspector")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 52)
    }

    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if collapsed.contains(id) {
                collapsed.remove(id)
            } else {
                collapsed.insert(id)
            }
        }
    }

    private var reviewBar: some View {
        HStack(spacing: 10) {
            Label(
                "\(chatStore.reviewComments.count) \(chatStore.reviewComments.count == 1 ? "comment" : "comments")",
                systemImage: "text.bubble"
            )
            .font(.system(size: 11.5, weight: .medium))

            if chatStore.outdatedReviewCommentCount > 0 {
                Menu {
                    ForEach(chatStore.reviewComments.filter(\.isOutdated)) { comment in
                        Button(role: .destructive) {
                            chatStore.removeReviewComment(comment.id)
                        } label: {
                            Label(
                                "Remove \(comment.anchor.filePath):\(comment.anchor.lineNumber)",
                                systemImage: "trash"
                            )
                        }
                    }
                } label: {
                    Label(
                        "\(chatStore.outdatedReviewCommentCount) outdated",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(AppTypography.metadata)
                    .foregroundStyle(.orange)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Refresh or remove outdated comments before sending")
            }

            Spacer(minLength: 8)

            Button("Discard") {
                showsDiscardConfirmation = true
            }
            .buttonStyle(.borderless)
            .disabled(chatStore.busy)

            Button("Send Review") {
                editingLineID = nil
                Task { await chatStore.sendReviewComments() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!chatStore.canSendReviewComments)
            .help(reviewSendHelp)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var reviewSendHelp: String {
        if chatStore.outdatedReviewCommentCount > 0 {
            return "Refresh or remove outdated comments before sending"
        }
        if chatStore.busy { return "Wait for the current response to finish" }
        return "Send all review comments as one request"
    }

    private func saveComment(
        id: UUID?,
        anchor: ReviewLineAnchor,
        body: String
    ) {
        _ = chatStore.upsertReviewComment(id: id, anchor: anchor, body: body)
        editingLineID = nil
    }

    private func removeComment(_ id: UUID) {
        chatStore.removeReviewComment(id)
        editingLineID = nil
    }
}

// MARK: - File Section

struct DiffSectionView: View {
    let section: FileDiffSection
    let isCollapsed: Bool
    fileprivate let contextMode: DiffContextMode
    let viewportWidth: CGFloat
    let contentWidth: CGFloat
    let gutterWidth: CGFloat
    let syntaxTokensByLineID: [UUID: [InspectorSyntaxToken]]
    let comments: [ReviewComment]
    @Binding var editingLineID: UUID?
    let onToggle: () -> Void
    let onSaveComment: (UUID?, ReviewLineAnchor, String) -> Void
    let onRemoveComment: (UUID) -> Void
    @State private var revealedContextIndices: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                sectionHeader
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed, !section.diffLines.isEmpty {
                DiffLinesView(
                    rows: displayRows,
                    allLines: section.diffLines,
                    filePath: section.path,
                    viewportWidth: viewportWidth,
                    contentWidth: contentWidth,
                    gutterWidth: gutterWidth,
                    syntaxTokensByLineID: syntaxTokensByLineID,
                    comments: comments,
                    editingLineID: $editingLineID,
                    onRevealOmitted: reveal,
                    onSaveComment: onSaveComment,
                    onRemoveComment: onRemoveComment
                )
            }
        }
        .frame(width: contentWidth, alignment: .leading)
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            Image(systemName: InspectorFilePresentation.symbolName(for: section.path))
                .font(.system(size: 12))
                .foregroundStyle(
                    InspectorFilePresentation.supportsSyntaxHighlighting(section.path)
                        ? Color.orange
                        : Color(nsColor: .secondaryLabelColor)
                )
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(section.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(1)

                if section.path != section.fileName {
                    Text(section.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                if section.added > 0 {
                    Text("+\(section.added)")
                        .foregroundStyle(.green)
                }
                if section.removed > 0 {
                    Text("-\(section.removed)")
                        .foregroundStyle(.red)
                }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(width: viewportWidth)
        .frame(minHeight: 42)
    }

    private var displayRows: [InspectorDiffRow] {
        switch contextMode {
        case .full:
            return section.diffLines.enumerated().map { index, line in
                InspectorDiffRow(
                    id: "line-\(index)-\(line.id)",
                    content: .line(index: index, line: line)
                )
            }
        case .focused:
            return InspectorDiffRowBuilder.focusedRows(
                section.diffLines,
                contextRadius: 3,
                revealedIndices: revealedContextIndices
            )
        }
    }

    private func reveal(_ range: ClosedRange<Int>) {
        withAnimation(.easeInOut(duration: 0.16)) {
            revealedContextIndices.formUnion(range)
        }
    }
}

// MARK: - Focused diff presentation

/// Builds compact context groups independently from the view so revealing one
/// omitted region never forces the entire file into Full mode.
nonisolated enum InspectorDiffRowBuilder {
    static func focusedRows(
        _ lines: [DiffLine],
        contextRadius: Int,
        revealedIndices: Set<Int> = []
    ) -> [InspectorDiffRow] {
        let changedIndices = lines.indices.filter { lines[$0].type != .context }
        guard !changedIndices.isEmpty else { return [] }

        var visibleIndices = revealedIndices
        for index in changedIndices {
            let lower = max(lines.startIndex, index - contextRadius)
            let upper = min(lines.endIndex - 1, index + contextRadius)
            visibleIndices.formUnion(lower...upper)
        }

        var rows: [InspectorDiffRow] = []
        var omittedStart: Int?

        func appendOmitted(endingAt end: Int) {
            guard let start = omittedStart else { return }
            let range = start...end
            rows.append(
                InspectorDiffRow(
                    id: "omitted-\(start)-\(end)",
                    content: .omitted(range)
                )
            )
            omittedStart = nil
        }

        for index in lines.indices {
            if visibleIndices.contains(index) {
                appendOmitted(endingAt: index - 1)
                rows.append(
                    InspectorDiffRow(
                        id: "line-\(index)-\(lines[index].id)",
                        content: .line(index: index, line: lines[index])
                    )
                )
            } else if omittedStart == nil {
                omittedStart = index
            }
        }
        appendOmitted(endingAt: lines.endIndex - 1)
        return rows
    }
}

// MARK: - Diff Rows

nonisolated struct InspectorDiffRow: Identifiable, Sendable {
    nonisolated enum Content: Sendable {
        case line(index: Int, line: DiffLine)
        case omitted(ClosedRange<Int>)
    }

    let id: String
    let content: Content
}

struct DiffLinesView: View {
    fileprivate let rows: [InspectorDiffRow]
    let allLines: [DiffLine]
    let filePath: String
    let viewportWidth: CGFloat
    let contentWidth: CGFloat
    let gutterWidth: CGFloat
    let syntaxTokensByLineID: [UUID: [InspectorSyntaxToken]]
    let comments: [ReviewComment]
    @Binding var editingLineID: UUID?
    let onRevealOmitted: (ClosedRange<Int>) -> Void
    let onSaveComment: (UUID?, ReviewLineAnchor, String) -> Void
    let onRemoveComment: (UUID) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                switch row.content {
                case .line(let index, let line):
                    lineRow(index: index, line: line)
                case .omitted(let range):
                    omittedRow(range)
                        .frame(width: contentWidth, alignment: .leading)
                }
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .textSelection(.enabled)
        .frame(width: contentWidth, alignment: .leading)
    }

    @ViewBuilder
    private func lineRow(index: Int, line: DiffLine) -> some View {
        if let anchor = ReviewLineAnchor.make(
            filePath: filePath,
            lineIndex: index,
            lines: allLines
        ) {
            let comment = comment(matching: anchor)
            VStack(alignment: .leading, spacing: 0) {
                DiffLineView(
                    line: line,
                    tokens: syntaxTokensByLineID[line.id] ?? [],
                    gutterWidth: gutterWidth,
                    hasComment: comment != nil,
                    isEditing: editingLineID == line.id,
                    onRequestComment: { editingLineID = line.id }
                )
                .frame(width: contentWidth, alignment: .leading)

                if editingLineID == line.id {
                    ReviewCommentEditor(
                        anchor: anchor,
                        existingComment: comment,
                        gutterWidth: gutterWidth,
                        onCancel: { editingLineID = nil },
                        onSave: { body in
                            onSaveComment(comment?.id, anchor, body)
                        },
                        onRemove: comment.map { existing in
                            { onRemoveComment(existing.id) }
                        }
                    )
                    .frame(width: viewportWidth, alignment: .leading)
                }
            }
        } else {
            DiffLineView(
                line: line,
                tokens: syntaxTokensByLineID[line.id] ?? [],
                gutterWidth: gutterWidth,
                hasComment: false,
                isEditing: false,
                onRequestComment: nil
            )
            .frame(width: contentWidth, alignment: .leading)
        }
    }

    private func comment(matching anchor: ReviewLineAnchor) -> ReviewComment? {
        comments.first {
            !$0.isOutdated
                && $0.anchor.filePath == anchor.filePath
                && $0.anchor.side == anchor.side
                && $0.anchor.lineNumber == anchor.lineNumber
                && $0.anchor.content == anchor.content
        }
    }

    private func omittedRow(_ range: ClosedRange<Int>) -> some View {
        let count = range.count
        return Button {
            onRevealOmitted(range)
        } label: {
            HStack(spacing: 0) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: gutterWidth)

                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(width: 0.5)

                Text("\(count) unmodified \(count == 1 ? "line" : "lines")")
                    .padding(.leading, 14)

                Spacer(minLength: 8)
            }
            .foregroundStyle(.secondary)
            .frame(width: viewportWidth, alignment: .leading)
            .frame(minHeight: 34)
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .help("Show \(count) unmodified \(count == 1 ? "line" : "lines")")
    }
}

struct DiffLineView: View {
    let line: DiffLine
    let tokens: [InspectorSyntaxToken]
    let gutterWidth: CGFloat
    let hasComment: Bool
    let isEditing: Bool
    let onRequestComment: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                Text(number(line.newLineNumber ?? line.oldLineNumber))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 9)
                    .foregroundStyle(isEditing ? Color.accentColor : .secondary)

                if let onRequestComment, isHovering || hasComment || isEditing {
                    Button(action: onRequestComment) {
                        Image(systemName: hasComment ? "text.bubble.fill" : "plus")
                            .font(.system(size: hasComment ? 8 : 10, weight: .bold))
                            .foregroundStyle(
                                Color(nsColor: .alternateSelectedControlTextColor)
                            )
                            .frame(width: 22, height: 22)
                            .background(
                                hasComment || isEditing ? Color.accentColor : Color.primary.opacity(0.8),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .offset(x: 11)
                    .zIndex(2)
                    .help(hasComment ? "Edit line comment" : "Comment on this line")
                    .accessibilityLabel(
                        hasComment
                            ? "Edit comment on line \(number(line.newLineNumber ?? line.oldLineNumber))"
                            : "Comment on line \(number(line.newLineNumber ?? line.oldLineNumber))"
                    )
                }
            }
            .frame(width: gutterWidth, height: 22)
            .background(resolvedGutterBackground)

            Rectangle()
                .fill(stripeColor)
                .frame(width: 2, height: 22)

            Text(prefix)
                .foregroundStyle(prefixColor)
                .frame(width: 18, alignment: .center)

            Text(attributedContent)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 12)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .background(resolvedContentBackground)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private func number(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    private var gutterBackground: Color {
        switch line.type {
        case .added: return .green.opacity(0.13)
        case .removed: return .red.opacity(0.13)
        case .context: return .clear
        }
    }

    private var resolvedGutterBackground: Color {
        isEditing ? Color.accentColor.opacity(0.17) : gutterBackground
    }

    private var contentBackground: Color {
        switch line.type {
        case .added: return .green.opacity(0.075)
        case .removed: return .red.opacity(0.075)
        case .context: return .clear
        }
    }

    private var resolvedContentBackground: Color {
        isEditing ? Color.accentColor.opacity(0.12) : contentBackground
    }

    private var attributedContent: AttributedString {
        let source = tokens.isEmpty
            ? [InspectorSyntaxToken(text: line.content, kind: .plain)]
            : tokens
        var result = AttributedString()
        for token in source {
            var segment = AttributedString(token.text)
            segment.foregroundColor = syntaxColor(token.kind)
            result.append(segment)
        }
        if result.characters.isEmpty {
            var blank = AttributedString(" ")
            blank.foregroundColor = syntaxColor(.plain)
            result.append(blank)
        }
        return result
    }

    private func syntaxColor(_ kind: InspectorSyntaxTokenKind) -> Color {
        switch kind {
        case .plain: Color(nsColor: .labelColor).opacity(0.86)
        case .keyword: Color(nsColor: .systemPurple)
        case .type: Color(nsColor: .systemTeal)
        case .attribute: Color(nsColor: .systemPink)
        case .number: Color(nsColor: .systemBlue)
        case .string: Color(nsColor: .systemRed)
        case .comment: Color(nsColor: .secondaryLabelColor)
        }
    }

    private var prefix: String {
        switch line.type {
        case .added: return "+"
        case .removed: return "-"
        case .context: return ""
        }
    }

    private var prefixColor: Color {
        switch line.type {
        case .added: return .green
        case .removed: return .red
        case .context: return .clear
        }
    }

    private var stripeColor: Color {
        switch line.type {
        case .added: return .green.opacity(0.7)
        case .removed: return .red.opacity(0.7)
        case .context: return .clear
        }
    }
}

/// Inline editor anchored below one diff row. It mirrors the native review
/// interaction used by developer tools while keeping comment submission local
/// until the explicit Send Review action aggregates the complete draft.
private struct ReviewCommentEditor: View {
    let anchor: ReviewLineAnchor
    let existingComment: ReviewComment?
    let gutterWidth: CGFloat
    let onCancel: () -> Void
    let onSave: (String) -> Void
    let onRemove: (() -> Void)?

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(
        anchor: ReviewLineAnchor,
        existingComment: ReviewComment?,
        gutterWidth: CGFloat,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void,
        onRemove: (() -> Void)?
    ) {
        self.anchor = anchor
        self.existingComment = existingComment
        self.gutterWidth = gutterWidth
        self.onCancel = onCancel
        self.onSave = onSave
        self.onRemove = onRemove
        _draft = State(initialValue: existingComment?.body ?? "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.accentColor.opacity(0.15)
                .frame(width: gutterWidth + 2)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 12, weight: .medium))
                    Text("Local comment")
                        .font(.system(size: 12.5, weight: .semibold))

                    Spacer(minLength: 8)

                    Text(locationLabel)
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)

                    if let onRemove {
                        Button(role: .destructive, action: onRemove) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete comment")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 42)

                Divider()

                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Request change")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $draft)
                        .font(.system(size: 12.5))
                        .scrollContentBackground(.hidden)
                        .focused($isFocused)
                        .frame(minHeight: 58, maxHeight: 92)
                }
                .padding(.horizontal, 8)
                .padding(.top, 3)

                HStack(spacing: 9) {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.borderless)
                    Button(existingComment == nil ? "Comment" : "Update") {
                        onSave(draft)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color.accentColor.opacity(0.055))
        .onExitCommand(perform: onCancel)
        .task { isFocused = true }
    }

    private var locationLabel: String {
        let side = anchor.side == .current ? "R" : "L"
        return "Comment on line \(side)\(anchor.lineNumber)"
    }
}

/// The inspector is deliberately denser than the document-modal review. One
/// contextual line number and a measured content canvas keep narrow panes useful
/// without wrapping or clipping long source lines.
private enum InspectorDiffLayout {
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let markerWidth: CGFloat = 20

    static func gutterWidth(for lines: [DiffLine]) -> CGFloat {
        let largest = lines.reduce(0) { partial, line in
            max(partial, max(line.oldLineNumber ?? 0, line.newLineNumber ?? 0))
        }
        let measured = (String(largest) as NSString).size(
            withAttributes: [.font: codeFont]
        ).width
        return max(42, measured + 18)
    }

    static func minimumContentWidth(
        for lines: [DiffLine],
        gutterWidth: CGFloat
    ) -> CGFloat {
        let longest = lines.reduce(CGFloat.zero) { width, line in
            let measured = (line.content as NSString).size(
                withAttributes: [.font: codeFont]
            ).width
            return max(width, measured)
        }
        return gutterWidth + markerWidth + longest + 24
    }
}
