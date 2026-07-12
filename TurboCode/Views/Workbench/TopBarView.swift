import SwiftUI

// MARK: - TopBarView

struct TopBarView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        HStack(spacing: 8) {
            Spacer()

            workspaceMenu

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

    private var workspaceMenu: some View {
        Menu {
            if !chatStore.workspaceRoot.isEmpty {
                Button {
                    chatStore.chooseWorkspace()
                } label: {
                    Label("Change workspace...", systemImage: "arrow.triangle.swap")
                }
            }

            if !chatStore.recentWorkspaces.isEmpty {
                Section("Recent") {
                    ForEach(chatStore.recentWorkspaces, id: \.self) { path in
                        let name = URL(fileURLWithPath: path).lastPathComponent
                        Button {
                            chatStore.switchToWorkspace(path)
                        } label: {
                            HStack {
                                Text(name)
                                if path == chatStore.workspaceRoot {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            Button {
                chatStore.chooseWorkspace()
            } label: {
                Label("Choose workspace...", systemImage: "folder")
            }
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
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
    }
}
