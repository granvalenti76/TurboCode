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
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
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

                    if chatStore.busy {
                        ModelActivityIndicator(summary: modelActivitySummary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .id("model-activity")
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
            .onChange(of: chatStore.busy) { _, _ in
                if autoScroll { scrollToBottom(proxy) }
            }
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
        Markdown(text)
            .markdownTheme(AppTypography.chatMarkdownTheme(size: chatFontSize))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }
}
