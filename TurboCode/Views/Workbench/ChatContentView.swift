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

            if chatStore.terminalOpen {
                Divider()
                TerminalPlaceholderView()
                    .frame(height: chatStore.terminalHeight)
            }

            InputFieldView()
        }
    }
}
