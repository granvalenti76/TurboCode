import SwiftUI

// MARK: - SidebarView

struct SidebarView: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var isSessionSearchPresented = false
    @State private var expandedWorkspaces: Set<String> = []
    @State private var workspacePendingRemoval: String?

    var body: some View {
        VStack(spacing: 0) {
            headerView
            navItemsView
            List {
                projectsSection
                chatsSection
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
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
        .alert("Remove Workspace?", isPresented: workspaceRemovalPresented) {
            Button("Cancel", role: .cancel) {
                workspacePendingRemoval = nil
            }
            Button("Remove", role: .destructive) {
                guard let path = workspacePendingRemoval else { return }
                workspacePendingRemoval = nil
                expandedWorkspaces.remove(path)
                Task { await chatStore.removeWorkspace(path) }
            }
        } message: {
            Text(workspaceRemovalMessage)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("TurboCode")
                .font(AppTypography.sidebarHeader)

            Spacer()

            Button {
                isSessionSearchPresented.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search")
            .popover(isPresented: $isSessionSearchPresented, arrowEdge: .top) {
                SessionSearchView(conversations: chatStore.threads) { thread in
                    isSessionSearchPresented = false
                    openThread(thread)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Navigation Items

    private var navItemsView: some View {
        VStack(spacing: 2) {
            Button {
                chatStore.setRoute(.chat)
                Task { await chatStore.createThread() }
            } label: {
                navigationLabel(icon: "square.and.pencil", title: "New Chat")
            }
            .buttonStyle(.plain)

            ForEach(NavItem.allCases, id: \.self) { item in
                Button {
                    chatStore.setRoute(item.route)
                } label: {
                    navigationLabel(
                        icon: item.icon,
                        title: item.label,
                        isSelected: chatStore.route == item.route
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func navigationLabel(
        icon: String,
        title: String,
        isSelected: Bool = false
    ) -> some View {
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
        .sidebarSelectionBackground(isSelected)
    }

    private enum NavItem: CaseIterable {
        case tools
        case skills

        var label: String {
            switch self {
            case .tools: "Tools"
            case .skills: "Custom Profiles"
            }
        }
        var icon: String {
            switch self {
            case .tools: return "hammer"
            case .skills: return "doc.text"
            }
        }
        var route: AppRoute {
            switch self {
            case .tools: .tools
            case .skills: .skills
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
        .padding(.leading, 6)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .textCase(nil)
    }

    // MARK: - Projects Section

    private var projectsSection: some View {
        Section {
            // All threads
            Button {
                chatStore.setRoute(.chat)
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
                    Text("All Chats")
                        .font(AppTypography.sidebarLabel)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .sidebarSelectionBackground(
                    chatStore.selectedProject == nil && chatStore.activeThreadId == nil
                )
            }
            .buttonStyle(.plain)
            .listRowInsets(sidebarRowInsets)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            // Recent workspace projects with expandable sessions
            ForEach(chatStore.recentWorkspaces, id: \.self) { path in
                let isExpanded = expandedWorkspaces.contains(path)

                workspaceRow(path: path, isExpanded: isExpanded)

                // Keep each workspace's conversations visually attached to its
                // folder and let the user expand more than one project.
                if isExpanded {
                    let workspaceThreads = threads(forWorkspace: path)
                    if workspaceThreads.isEmpty {
                        Text("No chats in this project")
                            .font(AppTypography.sidebarMetadata)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .listRowInsets(EdgeInsets(top: 0, leading: 52, bottom: 0, trailing: 10))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(workspaceThreads.prefix(10)) { thread in
                            threadRow(for: thread)
                                .listRowInsets(EdgeInsets(top: 0, leading: 38, bottom: 0, trailing: 10))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
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
                    Text("Add workspace…")
                        .font(AppTypography.sidebarLabel)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(sidebarRowInsets)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            sectionHeader("Projects")
        }
    }

    private func workspaceRow(path: String, isExpanded: Bool) -> some View {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let isSelected = chatStore.workspaceRoot == path && chatStore.selectedProject != nil

        return Button {
            chatStore.setRoute(.chat)
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
                    .lineLimit(1)
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
        .listRowInsets(sidebarRowInsets)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                workspacePendingRemoval = path
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .tint(.red)
        }
        .contextMenu {
            Button("Remove Workspace…", role: .destructive) {
                workspacePendingRemoval = path
            }
        }
    }

    // MARK: - Chats Section

    private var chatsSection: some View {
        Section {
            if chatStore.selectedProject == nil {
                if chatStore.threads.isEmpty {
                    emptyChatsView
                } else {
                    chatsList
                }
            }
        } header: {
            if chatStore.selectedProject == nil {
                sectionHeader("Chats")
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
        .padding(.vertical, 20)
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var chatsList: some View {
        ForEach(chatStore.sortedThreads.prefix(10)) { thread in
            threadRow(for: thread)
                .listRowInsets(sidebarRowInsets)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    private var sidebarRowInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
    }

    private var workspaceRemovalPresented: Binding<Bool> {
        Binding(
            get: { workspacePendingRemoval != nil },
            set: { isPresented in
                if !isPresented { workspacePendingRemoval = nil }
            }
        )
    }

    private var workspaceRemovalMessage: String {
        guard let path = workspacePendingRemoval else { return "" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let chatCount = chatStore.threads.filter { $0.workspace == path }.count
        let chats = chatCount == 1 ? "1 associated chat" : "\(chatCount) associated chats"
        return "This removes \(name) and \(chats) from TurboCode. Files in the workspace will not be deleted."
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
                openThread(thread)
            },
            onRename: { newTitle in Task { await chatStore.renameThread(id: thread.id, title: newTitle) } },
            onPin: { Task { await chatStore.pinThread(id: thread.id, pinned: !thread.isPinned) } },
            onArchive: { Task { await chatStore.archiveThread(id: thread.id) } },
            onDelete: { Task { await chatStore.deleteThread(id: thread.id) } },
            onRestore: { Task { await chatStore.restoreThread(id: thread.id) } }
        )
    }

    private func openThread(_ thread: Conversation) {
        chatStore.setRoute(.chat)
        Task {
            // If blocks are empty, it's a restored session — load full data.
            if chatStore.blocks.isEmpty || chatStore.activeThreadId != thread.id {
                await chatStore.restoreSession(id: thread.id)
            } else {
                await chatStore.selectThread(thread.id)
            }
        }
    }

}
