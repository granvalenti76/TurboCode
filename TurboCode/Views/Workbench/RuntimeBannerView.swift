import SwiftUI

// MARK: - RuntimeBannerView

struct RuntimeBannerView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        if chatStore.runtimeStatus != .ready {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if chatStore.runtimeStatus == .disconnected {
                    Button("Connect") {
                        chatStore.runtimeStatus = .connecting
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

    private var statusColor: Color {
        switch chatStore.runtimeStatus {
        case .disconnected: return .red
        case .connecting: return .orange
        case .ready: return .green
        case .error: return .red
        }
    }

    private var statusText: String {
        switch chatStore.runtimeStatus {
        case .disconnected: return "Runtime disconnected"
        case .connecting: return "Connecting to runtime..."
        case .ready: return ""
        case .error: return "Runtime error"
        }
    }
}
