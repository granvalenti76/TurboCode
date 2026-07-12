import SwiftUI

// MARK: - ChatContentView

struct ChatContentView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        VStack(spacing: 0) {
            RuntimeBannerView()

            if chatStore.blocks.isEmpty && chatStore.liveAssistant.isEmpty && chatStore.liveReasoning.isEmpty {
                emptyState
            } else {
                MessageTimelineView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 16) {
            VStack(spacing: 0) {
                if chatStore.terminalOpen {
                    Divider()
                    TerminalPlaceholderView()
                        .frame(height: chatStore.terminalHeight)
                }
                InputFieldView()
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("What should we build in TurboCode?")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.primary)
            Text("Ask anything or describe what you want to create")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
}
