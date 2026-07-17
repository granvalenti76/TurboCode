import SwiftUI

// MARK: - ChatContentView

struct ChatContentView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(SettingsStore.self) private var settings

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
                    .font(AppTypography.emptyStateTitle)
                    .foregroundStyle(.primary)

                Text("Ask anything or describe what you want to create")
                    .font(AppTypography.emptyStateSubtitle)
                    .foregroundStyle(.secondary)
            }

            InputFieldView(compact: true)
                .frame(maxWidth: min(CGFloat(settings.maxChatWidth), 720))

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
                .frame(maxWidth: CGFloat(settings.maxChatWidth))
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Approval Banner

    @ViewBuilder
    private func approvalBanner(_ approval: ApprovalRequest) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text(approval.displaySummary)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button(role: approval.operation == "removeFile" ? .destructive : nil) {
                chatStore.approveAction()
            } label: {
                Text(approval.operation == "removeFile" ? "Delete" : "Allow")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                chatStore.rejectAction()
            } label: {
                Text(approval.operation == "removeFile" ? "Cancel" : "Deny")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
