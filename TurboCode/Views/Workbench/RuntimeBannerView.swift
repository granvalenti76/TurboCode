import SwiftUI

// MARK: - RuntimeBannerView

struct RuntimeBannerView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(ChatPresentationViewModel.self) private var presentation

    var body: some View {
        if chatStore.activeBackend == .codex {
            codexBanner
        } else if presentation.runtimeStatus != .ready {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if presentation.runtimeStatus == .disconnected {
                    Button("Connect") {
                        presentation.runtimeStatus = .connecting
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(statusColor.opacity(0.08))
        }
    }

    @ViewBuilder
    private var codexBanner: some View {
        switch chatStore.codexConnectionState {
        case .idle, .connecting:
            statusBanner(
                color: .orange,
                text: "Checking Codex runtime and Luna availability…"
            ) {
                ProgressView()
                    .controlSize(.small)
            }
        case .signedOut:
            statusBanner(
                color: .orange,
                text: "Sign in with ChatGPT to use Codex · Luna"
            ) {
                Button("Sign In") {
                    chatStore.signInToCodex()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        case .authenticating:
            statusBanner(
                color: .orange,
                text: "Complete Codex sign-in in your browser…"
            ) {
                if chatStore.codexLoginURL != nil {
                    Button("Open Browser") {
                        chatStore.reopenCodexLoginPage()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        case .failed(let message):
            statusBanner(
                color: .red,
                text: message
            ) {
                Button("Retry") {
                    chatStore.retryCodexConnection()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        case .ready:
            EmptyView()
        }
    }

    private func statusBanner<Actions: View>(
        color: Color,
        text: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            actions()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
    }

    private var statusColor: Color {
        switch presentation.runtimeStatus {
        case .disconnected: return .red
        case .connecting: return .orange
        case .ready: return .green
        case .error: return .red
        }
    }

    private var statusText: String {
        switch presentation.runtimeStatus {
        case .disconnected: return "Runtime disconnected"
        case .connecting: return "Connecting to runtime..."
        case .ready: return ""
        case .error: return "Runtime error"
        }
    }
}
