import SwiftUI

// MARK: - Native Toolbar Workspace Menu

struct WorkspaceToolbarMenu: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        workspaceMenu
    }

    private var workspaceMenu: some View {
        Menu {
            if !chatStore.workspaceRoot.isEmpty {
                Button {
                    chatStore.chooseWorkspace()
                } label: {
                    Label("Change workspace…", systemImage: "arrow.triangle.swap")
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
                Label("Choose workspace…", systemImage: "folder")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: chatStore.workspaceRoot.isEmpty ? "folder" : "folder.fill")
                    .font(AppTypography.control)
                Text(chatStore.workspaceLabel)
                    .font(AppTypography.controlEmphasized)
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
            }
        }
        .fixedSize()
    }
}
