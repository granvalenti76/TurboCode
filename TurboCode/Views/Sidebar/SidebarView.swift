import SwiftUI

// MARK: - SidebarView

struct SidebarView: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var isSessionSearchPresented = false
    @State private var workspacePendingRemoval: String?

    var body: some View {
        VStack(spacing: 0) {
            headerView
            List {
                primaryActionsSection
                utilitiesSection
                projectsSection
                chatsSection
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)
        }
        .background(Color.clear)
        .frame(minWidth: 240)
        .alert("Remove Workspace?", isPresented: workspaceRemovalPresented) {
            Button("Cancel", role: .cancel) {
                workspacePendingRemoval = nil
            }
            Button("Remove", role: .destructive) {
                guard let path = workspacePendingRemoval else { return }
                workspacePendingRemoval = nil
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

    // MARK: - Primary Actions

    /// Keep global actions inside the source list so focus, keyboard navigation,
    /// selection spacing, and scrolling follow the same macOS behavior as projects.
    private var primaryActionsSection: some View {
        Section {
            Button {
                chatStore.setRoute(.chat)
                Task { await chatStore.createThread() }
            } label: {
                navigationLabel(icon: "square.and.pencil", title: "New Chat")
            }
            .buttonStyle(.plain)
            .listRowInsets(sidebarRowInsets)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Button {
                chatStore.setRoute(.chat)
                // "All Chats" changes only the visible collection; the active
                // workspace remains available to tools and to the next new chat.
                chatStore.selectedProject = nil
            } label: {
                navigationLabel(
                    icon: "tray.full",
                    title: "All Chats",
                    // A conversation is the primary selection when one is open;
                    // the section heading still communicates the active collection.
                    isSelected: chatStore.route == .chat
                        && chatStore.selectedProject == nil
                        && chatStore.activeThreadId == nil
                )
            }
            .buttonStyle(.plain)
            .listRowInsets(sidebarRowInsets)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
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

    // MARK: - Utilities

    /// Secondary destinations stay in the same native source list but remain
    /// visually separate from project and conversation navigation.
    private var utilitiesSection: some View {
        Section {
            ForEach(UtilityItem.allCases, id: \.self) { item in
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
                .listRowInsets(sidebarRowInsets)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        } header: {
            sectionHeader("Utilities")
        }
    }

    private enum UtilityItem: CaseIterable {
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
            // Workspaces are collection filters, not disclosure containers. Keeping
            // conversations in one section prevents the same thread appearing twice.
            ForEach(chatStore.recentWorkspaces, id: \.self) { path in
                workspaceRow(path: path)
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

    private func workspaceRow(path: String) -> some View {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let isActiveWorkspace = chatStore.workspaceRoot == path
        let isSelectedCollection = chatStore.selectedProject == name

        return Button {
            chatStore.setRoute(.chat)
            // Browsing a collection must not silently retarget tools, Git, or a
            // draft message. The toolbar remains the explicit workspace switcher.
            chatStore.selectedProject = name
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isActiveWorkspace ? "folder.fill" : "folder")
                    .font(.system(size: 14))
                    .foregroundColor(isActiveWorkspace ? .blue : .secondary)
                    .frame(width: 20)
                Text(name)
                    .font(AppTypography.sidebarLabel)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .sidebarSelectionBackground(
                chatStore.route == .chat
                    && isSelectedCollection
                    && chatStore.activeThreadId == nil
            )
        }
        .buttonStyle(.plain)
        .help(isActiveWorkspace ? "Active workspace" : "Show chats in \(name)")
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
            if chatStore.sortedThreads.isEmpty {
                emptyChatsView
            } else {
                chatsList
            }
        } header: {
            sectionHeader(chatStore.selectedProject.map { "Chats — \($0)" } ?? "Chats")
        }
    }

    private var emptyChatsView: some View {
        HStack {
            Text(chatStore.selectedProject == nil ? "No chats" : "No chats in this project")
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
        // Keep ordering and filtering as value snapshots, but resolve each row
        // from the observable store so an asynchronously generated title is
        // immediately reflected without changing the row's stable identity.
        ForEach(chatStore.sortedThreads.prefix(10).map(\.id), id: \.self) { threadID in
            if let thread = chatStore.threads.first(where: { $0.id == threadID }) {
                threadRow(for: thread)
                    .listRowInsets(sidebarRowInsets)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
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

    private func threadRow(for thread: Conversation) -> some View {
        ThreadRowView(
            thread: thread,
            // Only the currently visible destination receives source-list
            // selection; an open chat stays available while browsing utilities.
            isSelected: chatStore.route == .chat && thread.id == chatStore.activeThreadId,
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
