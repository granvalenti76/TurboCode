import SwiftUI
import MarkdownUI

// MARK: - MessageTimelineView — scrollable, turn-based message list

/// Replicates Kun's MessageTimeline: block-based rendering with auto-scroll,
/// live streaming updates, and turn grouping.
struct MessageTimelineView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(SettingsStore.self) private var settings
    @Environment(\.chatFontSize) private var chatFontSize

    /// SwiftUI owns the concrete offset; the timeline only asks for the
    /// semantic bottom edge when the user is following the live response.
    @State private var scrollPosition = ScrollPosition(
        idType: String.self,
        edge: .bottom
    )
    /// These related flags move through one reducer so geometry and phase
    /// callbacks cannot leave the timeline in a contradictory state.
    @State private var scrollFollowState = TimelineScrollFollowState()
    /// Fast exploration calls remain legible long enough to communicate intent,
    /// then briefly acknowledge completion instead of flashing in and out.
    @State private var retainedExplorationActivity: ToolActivity?
    @State private var explorationStartedAt: Date?
    @State private var explorationIsComplete = false
    @State private var explorationDismissalGeneration = UUID()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Empty state
                if chatStore.blocks.isEmpty && chatStore.liveReasoning.isEmpty && chatStore.liveAssistant.isEmpty {
                    emptyState
                        .id("empty-state")
                }

                // Group blocks into turns
                let turns = groupBlocks(chatStore.blocks)

                ForEach(turns) { turn in
                    TurnView(turn: turn)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }

                // Live reasoning block (streaming)
                if !chatStore.liveReasoning.isEmpty {
                    LiveReasoningBlock(text: chatStore.liveReasoning)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .id("live-reasoning")
                }

                // Live assistant block (streaming)
                if !chatStore.liveAssistant.isEmpty {
                    LiveAssistantBlock(text: chatStore.liveAssistant)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .id("live-assistant")
                }

                if chatStore.busy || retainedExplorationActivity != nil {
                    modelActivityIndicator
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .id("model-activity")
                }

                // A stable target lets ScrollPosition preserve the bottom
                // through insertions, removals, and streamed text reflow.
                Color.clear
                    .frame(height: 1)
                    .id("bottom-anchor")
            }
            .scrollTargetLayout()
            .frame(maxWidth: CGFloat(settings.maxChatWidth))
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($scrollPosition, anchor: .bottom)
        .scrollContentBackground(.hidden)
        .onScrollGeometryChange(
            for: TimelineScrollSnapshot.self,
            of: TimelineScrollSnapshot.init
        ) { oldSnapshot, newSnapshot in
            // Geometry also changes while streamed Markdown wraps. It may
            // update the physical offset, but must not be mistaken for the
            // user's decision to leave the live edge.
            if scrollFollowState.updateGeometry(from: oldSnapshot, to: newSnapshot) {
                scrollToBottom()
            }
        }
        .onScrollPhaseChange { _, newPhase in
            scrollFollowState.updateScrollPhase(newPhase)
        }
        .task(id: chatStore.activeThreadId) {
            // A restored thread may replace blocks without changing their
            // count. Wait for its first layout before selecting the bottom.
            scrollFollowState.resetForConversation()
            await Task.yield()
            scrollToBottom()
        }
        .onAppear {
            updateExplorationPresentation(for: chatStore.activeToolActivity)
        }
        .onChange(of: chatStore.activeToolActivity) { _, activity in
            updateExplorationPresentation(for: activity)
        }
        .onDisappear {
            explorationDismissalGeneration = UUID()
        }
    }

    private var modelActivitySummary: String {
        if let activity = chatStore.activeToolActivity {
            return activity.summary
        }
        if chatStore.isDelegating {
            return "Waiting for the delegate model"
        }
        if !chatStore.liveAssistant.isEmpty {
            return "Composing response"
        }
        return "Preparing response"
    }

    /// File reads and searches share a deliberately quiet terminal affordance
    /// because fast workspace exploration can look like an idle model pause.
    @ViewBuilder
    private var modelActivityIndicator: some View {
        if let activity = chatStore.activeToolActivity,
           usesExplorationIndicator(activity) {
            ExplorationTerminalActivityIndicator(
                summary: activity.summary,
                isComplete: false
            )
        } else if chatStore.activeToolActivity == nil,
                  let activity = retainedExplorationActivity {
            ExplorationTerminalActivityIndicator(
                summary: activity.summary,
                isComplete: explorationIsComplete
            )
        } else {
            ModelActivityIndicator(summary: modelActivitySummary)
        }
    }

    private func usesExplorationIndicator(_ activity: ToolActivity) -> Bool {
        activity.toolName == "read_file"
            || activity.toolName == "ripgrep"
            || activity.toolName == "grep"
    }

    private func updateExplorationPresentation(for activity: ToolActivity?) {
        explorationDismissalGeneration = UUID()

        if let activity, usesExplorationIndicator(activity) {
            if retainedExplorationActivity?.id != activity.id {
                explorationStartedAt = Date()
            }
            retainedExplorationActivity = activity
            explorationIsComplete = false
            return
        }

        // Another tool is more relevant than an old exploration acknowledgement.
        guard activity == nil else {
            retainedExplorationActivity = nil
            explorationStartedAt = nil
            explorationIsComplete = false
            return
        }
        guard retainedExplorationActivity != nil else { return }

        explorationIsComplete = true
        let elapsed = Date().timeIntervalSince(explorationStartedAt ?? Date())
        let remainingMinimum = max(1.6 - elapsed, 0)
        let delay = max(remainingMinimum, 0.55)
        let generation = explorationDismissalGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard generation == explorationDismissalGeneration,
                  chatStore.activeToolActivity == nil else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                retainedExplorationActivity = nil
                explorationStartedAt = nil
                explorationIsComplete = false
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "message.and.waveform")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("Start a conversation")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Ask a question, give instructions, or share code")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360)
        .padding(.vertical, 80)
    }

    // MARK: - Helpers

    private func scrollToBottom() {
        // Streaming can relayout several times per second. Disabling animation
        // prevents overlapping scroll transactions and scrollbar thumb jitter.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }
}

/// The small Equatable projection keeps rapid geometry changes local to the
/// timeline instead of invalidating unrelated application state.
nonisolated struct TimelineScrollSnapshot: Equatable {
    static let bottomTolerance: CGFloat = 48

    let contentHeight: CGFloat
    let visibleMaxY: CGFloat

    init(contentHeight: CGFloat, visibleMaxY: CGFloat) {
        self.contentHeight = contentHeight
        self.visibleMaxY = visibleMaxY
    }

    init(_ geometry: ScrollGeometry) {
        self.init(
            contentHeight: geometry.contentSize.height,
            visibleMaxY: geometry.visibleRect.maxY
        )
    }

    var isNearBottom: Bool {
        contentHeight - visibleMaxY <= Self.bottomTolerance
    }
}

/// Owns the user-intent invariant for live scrolling. Content growth may
/// request a bottom adjustment, but only user-driven phases may disable it.
nonisolated struct TimelineScrollFollowState: Equatable {
    private(set) var followsLatestMessage = true
    private(set) var isNearBottom = true
    private(set) var isUserScrolling = false

    /// Returns true only when a non-user layout change should remain pinned to
    /// the bottom. Streaming callers use this to avoid per-token animations.
    mutating func updateGeometry(
        from oldSnapshot: TimelineScrollSnapshot,
        to newSnapshot: TimelineScrollSnapshot
    ) -> Bool {
        isNearBottom = newSnapshot.isNearBottom
        if isUserScrolling {
            followsLatestMessage = newSnapshot.isNearBottom
            return false
        }
        return followsLatestMessage
            && oldSnapshot.contentHeight != newSnapshot.contentHeight
    }

    mutating func updateScrollPhase(_ phase: ScrollPhase) {
        switch phase {
        case .tracking, .interacting, .decelerating:
            isUserScrolling = true
        case .idle:
            if isUserScrolling {
                followsLatestMessage = isNearBottom
            }
            isUserScrolling = false
        case .animating:
            // Programmatic movement must never disable live following.
            break
        }
    }

    mutating func resetForConversation() {
        followsLatestMessage = true
        isNearBottom = true
        isUserScrolling = false
    }
}

// MARK: - Model Activity Indicator

struct ModelActivityIndicator: View {
    let summary: String

    var body: some View {
        HStack(spacing: 7) {
            ActivityPulse()

            Text(summary)
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("\(summary), in progress")
    }
}

private struct ActivityPulse: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = (sin((time * 4.2) - (Double(index) * 0.9)) + 1) / 2
                    Capsule()
                        .fill(.secondary.opacity(0.42 + (wave * 0.4)))
                        .frame(width: 2.5, height: 5 + (wave * 5))
                }
            }
            .frame(width: 15, height: 12)
        }
    }
}

/// A low-frequency terminal cursor makes active workspace exploration visible
/// without competing with streamed reasoning or assistant text.
private struct ExplorationTerminalActivityIndicator: View {
    let summary: String
    let isComplete: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        if isComplete {
            content(cursorIsVisible: true)
        } else {
            TimelineView(.periodic(from: .now, by: 0.7)) { context in
                let cursorIsVisible = reduceMotion
                    || Int(context.date.timeIntervalSinceReferenceDate / 0.7).isMultiple(of: 2)
                content(cursorIsVisible: cursorIsVisible)
            }
        }
    }

    private func content(cursorIsVisible: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 1.5) {
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                } else {
                    Text("›")
                    RoundedRectangle(cornerRadius: 0.75)
                        .frame(width: 3, height: 8)
                        .opacity(cursorIsVisible ? 0.82 : 0.2)
                }
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 17)
            .background(.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 4.5))
            .overlay {
                RoundedRectangle(cornerRadius: 4.5)
                    .stroke(.separator.opacity(0.45), lineWidth: 0.5)
            }

            Text(summary)
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .opacity(isComplete ? 0.7 : 0.84)

            Spacer()
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isComplete ? "\(summary), completed" : "\(summary), in progress"
        )
    }
}

// MARK: - Turn grouping

struct Turn: Identifiable {
    let id: String
    let blocks: [ChatBlock]
}

private func groupBlocks(_ blocks: [ChatBlock]) -> [Turn] {
    var turns: [Turn] = []
    var currentGroup: [ChatBlock] = []
    var turnIndex = 0

    for block in blocks {
        if block.kind == .user {
            if !currentGroup.isEmpty {
                turns.append(
                    Turn(
                        id: turnID(for: currentGroup, fallback: turnIndex),
                        blocks: currentGroup
                    )
                )
                turnIndex += 1
                currentGroup = []
            }
        }
        currentGroup.append(block)
    }

    if !currentGroup.isEmpty {
        turns.append(
            Turn(
                id: turnID(for: currentGroup, fallback: turnIndex),
                blocks: currentGroup
            )
        )
    }

    return turns
}

/// A turn's identity follows its first block, not its current position. This
/// prevents SwiftUI from reusing a receipt row for another session or for a
/// newly inserted tool block.
private func turnID(for blocks: [ChatBlock], fallback: Int) -> String {
    blocks.first?.id ?? "turn-\(fallback)"
}

// MARK: - TurnView — renders one user→assistant exchange

struct TurnView: View {
    let turn: Turn

    var body: some View {
        VStack(spacing: 8) {
            ForEach(turn.blocks) { block in
                ChatBlockView(block: block)
            }
        }
    }
}

// MARK: - Live Reasoning Block (streaming)

struct LiveReasoningBlock: View {
    let text: String

    var body: some View {
        ReasoningDisclosure(text: text, isLive: true, textSize: 12)
    }
}

// MARK: - Reasoning Disclosure

struct ReasoningDisclosure: View {
    let text: String
    let isLive: Bool
    let textSize: CGFloat

    @State private var isExpanded = false
    @State private var isPulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                Text("Reasoning")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .opacity(isLive && isPulsing ? 0.42 : 0.86)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide reasoning" : "Show reasoning")

            if isExpanded {
                Text(formattedText(text))
                    .font(.system(size: textSize))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(.separator.opacity(0.55), lineWidth: 0.5)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .onAppear {
            guard isLive else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

// MARK: - Live Assistant Block (streaming)

struct LiveAssistantBlock: View {
    let text: String
    @Environment(\.chatFontSize) private var chatFontSize

    var body: some View {
        Markdown(ChatMarkdownPresentation.cleaned(text))
            .markdownTheme(AppTypography.chatMarkdownTheme(size: chatFontSize))
            .textSelection(.enabled)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }
}
