import SwiftUI

// MARK: - ChatContentView

struct ChatContentView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        VStack(spacing: 0) {
            RuntimeBannerView()

            if chatStore.isFirstMessage {
                firstMessageLayout
                    .transition(.opacity)
            } else {
                conversationLayout
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: chatStore.isFirstMessage)
    }

    // MARK: - First Message Layout (centered, narrow input)

    private var firstMessageLayout: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Text("What should we build in TurboCode?")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.primary)

                Text("Ask anything or describe what you want to create")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }

            InputFieldView()
                .frame(maxWidth: 600)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Conversation Layout (timeline + bottom input)

    private var conversationLayout: some View {
        VStack(spacing: 0) {
            MessageTimelineView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let approval = chatStore.pendingApproval {
                approvalBanner(approval)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if chatStore.terminalOpen {
                Divider()
                TerminalPlaceholderView()
                    .frame(height: chatStore.terminalHeight)
            }

            InputFieldView()
        }
    }

    // MARK: - Approval Banner

    @ViewBuilder
    private func approvalBanner(_ approval: ApprovalRequest) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 14))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Action requires approval")
                    .font(.system(size: 11, weight: .semibold))
                Text(approval.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                chatStore.approveAction()
            } label: {
                Text("Allow")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.green)

            Button {
                chatStore.rejectAction()
            } label: {
                Text("Deny")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.orange.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
