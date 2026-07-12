import SwiftUI

// MARK: - TopBarView

struct TopBarView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        HStack(spacing: 8) {
            Spacer()

            workspaceButton

            inspectorToggleButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.windowBackgroundColor))
    }

    private var inspectorToggleButton: some View {
        Button {
            chatStore.toggleRightPanel(.changes)
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 11))
                .foregroundStyle(chatStore.rightPanelVisible ? .primary : .tertiary)
        }
        .buttonStyle(.plain)
        .help("Toggle inspector panel")
    }

    private var workspaceButton: some View {
        Button {
            chatStore.chooseWorkspace()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: chatStore.workspaceRoot.isEmpty ? "folder" : "folder.fill")
                    .font(.system(size: 11))
                Text(chatStore.workspaceLabel)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(chatStore.workspaceRoot.isEmpty ? "Choose a workspace" : chatStore.workspaceRoot)
    }
}
