import SwiftUI
import MarkdownUI

// MARK: - MessageTimelineView — scrollable, turn-based message list

/// Replicates Kun's MessageTimeline: block-based rendering with auto-scroll,
/// live streaming updates, and turn grouping.
struct MessageTimelineView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(SettingsStore.self) private var settings
    @Environment(\.chatFontSize) private var chatFontSize
    @State private var scrollID: String?
    @State private var autoScroll: Bool = true

    var body: some View {
        ScrollViewReader { proxy in
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
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                    }

                    // Live reasoning block (streaming)
                    if !chatStore.liveReasoning.isEmpty {
                        LiveReasoningBlock(text: chatStore.liveReasoning)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                            .id("live-reasoning")
                    }

                    // Live assistant block (streaming)
                    if !chatStore.liveAssistant.isEmpty {
                        LiveAssistantBlock(text: chatStore.liveAssistant)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                            .id("live-assistant")
                    }

                    if let activity = chatStore.activeToolActivity {
                        ToolActivityIndicator(activity: activity)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                            .id("tool-activity-\(activity.id)")
                    }

                    // Bottom anchor for auto-scroll
                    Color.clear
                        .frame(height: 1)
                        .id("bottom-anchor")
                }
                .frame(maxWidth: CGFloat(settings.maxChatWidth))
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: chatStore.blocks.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: chatStore.liveAssistant) { _, _ in
                if autoScroll { scrollToBottom(proxy) }
            }
            .onChange(of: chatStore.activeToolActivity?.id) { _, _ in
                if autoScroll { scrollToBottom(proxy) }
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

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }
}

// MARK: - Tool Activity Indicator

struct ToolActivityIndicator: View {
    let activity: ToolActivity

    var body: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.mini)

            Text(activity.summary)
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("\(activity.summary), in progress")
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
                turns.append(Turn(id: "turn-\(turnIndex)", blocks: currentGroup))
                turnIndex += 1
                currentGroup = []
            }
        }
        currentGroup.append(block)
    }

    if !currentGroup.isEmpty {
        turns.append(Turn(id: "turn-\(turnIndex)", blocks: currentGroup))
    }

    return turns
}

// MARK: - TurnView — renders one user→assistant exchange

struct TurnView: View {
    let turn: Turn

    var body: some View {
        VStack(spacing: 6) {
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(.orange)
                .frame(width: 24, height: 24)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Reasoning")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                    ProgressView()
                        .scaleEffect(0.5)
                }

                Text(formattedText(text))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .padding(12)
        .background(.orange.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.orange.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Live Assistant Block (streaming)

struct LiveAssistantBlock: View {
    let text: String
    @Environment(\.chatFontSize) private var chatFontSize

    var body: some View {
        Markdown(text)
            .markdownTheme(AppTypography.chatMarkdownTheme(size: chatFontSize))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }
}
