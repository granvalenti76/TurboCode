import SwiftUI

// MARK: - SidebarView

struct SidebarView: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var searchText: String = ""
    @State private var selectedNav: String = "chat"
    @State private var expandedWorkspaces: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            headerView
            navItemsView
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    projectsSection
                    chatsSection
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)
        }
        .background(Color.clear)
        .frame(minWidth: 240)
        .onAppear {
            guard !chatStore.workspaceRoot.isEmpty else { return }
            expandedWorkspaces.insert(chatStore.workspaceRoot)
        }
        .onChange(of: chatStore.workspaceRoot) { _, workspace in
            guard !workspace.isEmpty else { return }
            expandedWorkspaces.insert(workspace)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("TurboCode")
                .font(.system(size: 22, weight: .semibold))

            Spacer()

            Button {
                selectedNav = "search"
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Navigation Items

    private var navItemsView: some View {
        VStack(spacing: 2) {
            Button {
                Task { await chatStore.createThread() }
            } label: {
                navigationLabel(icon: "square.and.pencil", title: "New chat")
            }
            .buttonStyle(.plain)

            ForEach(NavItem.allCases, id: \.self) { item in
                Button {
                    selectedNav = item.id
                } label: {
                    navigationLabel(icon: item.icon, title: item.label)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func navigationLabel(icon: String, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .frame(width: 20)
            Text(title)
                .font(AppTypography.sidebarLabel)
            Spacer()
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private enum NavItem: String, CaseIterable {
        case scheduled, plugins

        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .scheduled: return "clock"
            case .plugins: return "puzzlepiece.extension"
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(AppTypography.sectionLabel)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    // MARK: - Projects Section

    private var projectsSection: some View {
        VStack(spacing: 0) {
            sectionHeader("Projects")

            // All threads
            Button {
                chatStore.selectedProject = nil
                withAnimation(.easeInOut(duration: 0.18)) {
                    expandedWorkspaces.removeAll()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20)
                    Text("All chats")
                        .font(AppTypography.sidebarLabel)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .sidebarSelectionBackground(chatStore.selectedProject == nil)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)

            // Recent workspace projects with expandable sessions
            ForEach(chatStore.recentWorkspaces, id: \.self) { path in
                let name = URL(fileURLWithPath: path).lastPathComponent
                let isSelected = chatStore.workspaceRoot == path && chatStore.selectedProject != nil
                let isExpanded = expandedWorkspaces.contains(path)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if isExpanded {
                            expandedWorkspaces.remove(path)
                        } else {
                            expandedWorkspaces.insert(path)
                            if chatStore.workspaceRoot != path || !isSelected {
                                chatStore.switchToWorkspace(path)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected ? "folder.fill" : "folder")
                            .font(.system(size: 14))
                            .foregroundColor(isSelected ? .blue : .secondary)
                            .frame(width: 20)
                        Text(name)
                            .font(AppTypography.sidebarLabel)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)

                // Keep each workspace's conversations visually attached to its
                // folder and let the user expand more than one project.
                if isExpanded {
                    let workspaceThreads = threads(forWorkspace: path)
                    if workspaceThreads.isEmpty {
                        Text("No chats in this project")
                            .font(AppTypography.sidebarMetadata)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 52)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(workspaceThreads.prefix(10)) { thread in
                            threadRow(for: thread)
                                .padding(.leading, 38)
                                .padding(.trailing, 10)
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
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20)
                    Text("Add workspace...")
                        .font(AppTypography.sidebarLabel)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
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
                .padding(.horizontal, 10)
        }
    }

    private func threads(forWorkspace path: String) -> [Conversation] {
        chatStore.threads
            .filter { !$0.isArchived && $0.workspace == path }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
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
