import SwiftUI

// MARK: - SidebarView

struct SidebarView: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var searchText: String = ""
    @State private var selectedNav: String = "chat"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            Divider()
            // Navigation items
            navItemsView
            Divider()
            // Projects section
            projectsSection
            // Chats section
            chatsSection
            Spacer()
        }
        .background(Color.clear)
        .frame(minWidth: 220)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Button {
                Task { await chatStore.createThread() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .medium))
                    Text("New chat")
                        .font(AppTypography.controlEmphasized)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)

            Spacer()
        }
        .padding(.vertical, 8)
    }

    // MARK: - Navigation Items

    private var navItemsView: some View {
        VStack(spacing: 0) {
            ForEach(NavItem.allCases, id: \.self) { item in
                Button {
                    selectedNav = item.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.icon)
                            .font(.system(size: 13))
                            .frame(width: 18)
                        Text(item.label)
                            .font(AppTypography.sidebarLabel)
                        Spacer()
                        if let badge = item.badge {
                            Text(badge)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(selectedNav == item.id ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .sidebarSelectionBackground(selectedNav == item.id)
                }
                .buttonStyle(.plain)

            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private enum NavItem: String, CaseIterable {
        case search, scheduled, plugins

        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .search: return "magnifyingglass"
            case .scheduled: return "clock"
            case .plugins: return "puzzlepiece.extension"
            }
        }
        var badge: String? { nil }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(AppTypography.sectionLabel)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    // MARK: - Projects Section

    private var projectsSection: some View {
        VStack(spacing: 0) {
            sectionHeader("Projects")

            // All threads
            Button {
                chatStore.selectedProject = nil
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                    Text("All chats")
                        .font(AppTypography.sidebarLabel)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .sidebarSelectionBackground(chatStore.selectedProject == nil)
            }
            .buttonStyle(.plain)

            // Recent workspace projects with expandable sessions
            ForEach(chatStore.recentWorkspaces, id: \.self) { path in
                let name = URL(fileURLWithPath: path).lastPathComponent
                let isSelected = chatStore.selectedProject == name

                Button {
                    chatStore.switchToWorkspace(path)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected ? "folder.fill" : "folder")
                            .font(.system(size: 11))
                            .foregroundColor(isSelected ? .blue : .secondary)
                            .frame(width: 16)
                        Text(name)
                            .font(AppTypography.sidebarLabel)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .sidebarSelectionBackground(isSelected)
                }
                .buttonStyle(.plain)

                // Keep project conversations visually attached to the selected
                // workspace. The standalone Chats section is hidden in this
                // state, so the same thread never appears twice.
                if isSelected {
                    if chatStore.sortedThreads.isEmpty {
                        Text("No chats in this project")
                            .font(AppTypography.sidebarMetadata)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 36)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(chatStore.sortedThreads.prefix(10)) { thread in
                            threadRow(for: thread)
                                .padding(.leading, 20)
                        }
                    }
                }
            }

            // Add workspace
            Button {
                chatStore.chooseWorkspace()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                    Text("Add workspace...")
                        .font(AppTypography.sidebarLabel)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Chats Section

    private var chatsSection: some View {
        VStack(spacing: 0) {
            if chatStore.selectedProject == nil {
                sectionHeader("Chats")

                if chatStore.threads.isEmpty {
                    emptyChatsView
                } else {
                    chatsList
                }
            }
        }
    }

    private var emptyChatsView: some View {
        HStack {
            Text("No chats")
                .font(AppTypography.sidebarMetadata)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 20)
    }

    private var chatsList: some View {
        ForEach(chatStore.sortedThreads.prefix(10)) { thread in
            threadRow(for: thread)
        }
    }

    private func threadRow(for thread: Conversation) -> some View {
        ThreadRowView(
            thread: thread,
            isSelected: thread.id == chatStore.activeThreadId,
            onSelect: {
                Task {
                    // If blocks are empty, it's a restored session — load full data.
                    if chatStore.blocks.isEmpty || chatStore.activeThreadId != thread.id {
                        await chatStore.restoreSession(id: thread.id)
                    } else {
                        await chatStore.selectThread(thread.id)
                    }
                }
            },
            onRename: { newTitle in Task { await chatStore.renameThread(id: thread.id, title: newTitle) } },
            onPin: { Task { await chatStore.pinThread(id: thread.id, pinned: !thread.isPinned) } },
            onArchive: { Task { await chatStore.archiveThread(id: thread.id) } },
            onDelete: { Task { await chatStore.deleteThread(id: thread.id) } },
            onRestore: { Task { await chatStore.restoreThread(id: thread.id) } }
        )
    }

}
