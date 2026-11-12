import SwiftUI

/// Side answer to a progress question asked while a turn is running.
/// It sits above the composer like the steering queue, and is transient:
/// the answer comes from the on-device model and is not part of the chat.
struct TurnStatusCardView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.chatFontSize) private var chatFontSize

    private var bodyFont: Font {
        AppTypography.chatBody(size: max(13, chatFontSize - 3))
    }

    var body: some View {
        if let card = chatStore.turnStatusStore.card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Progress")
                        .font(AppTypography.sectionLabel)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Text(card.askedAt, style: .time)
                        .font(AppTypography.metadata)
                        .foregroundStyle(.tertiary)
                    Text("· \(card.question)")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(card.question)
                    Spacer(minLength: 8)
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        chatStore.turnStatusStore.refresh()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(AppTypography.metadata.weight(.semibold))
                    .disabled(card.phase == .generating || !chatStore.busy)
                    .help("Refresh the summary")
                    Button("Close", systemImage: "xmark") {
                        chatStore.turnStatusStore.dismiss()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(AppTypography.metadata.weight(.semibold))
                    .help("Close")
                }

                answer(card)

                HStack(spacing: 6) {
                    Text("On-device summary · not part of the conversation")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    // Recovery for a message that was an instruction after all.
                    Button("Send to Model") {
                        Task { await chatStore.sendTurnStatusQuestionToModel() }
                    }
                    .buttonStyle(.borderless)
                    .font(AppTypography.controlEmphasized)
                    .help("Deliver this message to the working model instead")
                }
            }
            .composerShelf()
            // A status answer belongs to the conversation it was asked in.
            .onChange(of: chatStore.activeThreadId) {
                chatStore.turnStatusStore.dismiss()
            }
        }
    }

    @ViewBuilder
    private func answer(_ card: TurnStatusStore.Card) -> some View {
        if card.phase == .failed {
            Label(
                "The summary is unavailable right now.",
                systemImage: "exclamationmark.triangle"
            )
            .font(bodyFont)
            .foregroundStyle(.secondary)
        } else if card.answer.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                Text("Reading the work in progress…")
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(card.answer)
                .font(bodyFont)
                .foregroundStyle(AppTypography.chatForeground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
