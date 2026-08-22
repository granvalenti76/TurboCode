import SwiftUI

// MARK: - ChatContentView

struct ChatContentView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(ChatPresentationViewModel.self) private var presentation
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            RuntimeBannerView()

            if let error = presentation.errorMessage {
                errorBanner(error)
            }

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

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                presentation.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.08))
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
                .overlay(alignment: .topTrailing) {
                    if let notice = presentation.localCompactionNotice {
                        LocalCompactionNoticeView(notice: notice) {
                            presentation.clearCompactionNotice()
                        }
                        .padding(.top, 10)
                        .padding(.trailing, 14)
                    }
                }

            if let approval = chatStore.pendingApproval {
                approvalBanner(approval)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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

private struct LocalCompactionNoticeView: View {
    let notice: LocalCompactionNotice
    let dismiss: () -> Void

    private var text: String {
        "Context compacted · ~\(shortCharacterCount(notice.sourceCharacters)) → ~\(shortCharacterCount(notice.retainedCharacters)) chars (estimate)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(AppTypography.metadata)
                .lineLimit(1)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss context compaction status")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().stroke(.separator.opacity(0.45), lineWidth: 0.5) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Context compacted, approximately \(notice.sourceCharacters) to \(notice.retainedCharacters) characters"
        )
    }

    private func shortCharacterCount(_ count: Int) -> String {
        if count >= 1_000_000 { return "\(count / 1_000_000)M" }
        if count >= 1_000 { return "\(count / 1_000)K" }
        return "\(count)"
    }
}
