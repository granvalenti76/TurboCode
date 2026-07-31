import SwiftUI

// MARK: - SidebarView

struct SidebarView: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var isSessionSearchPresented = false
    @State private var workspacePendingRemoval: String?
    @State private var visibleChatLimit = SidebarConversationDisclosure.batchSize
    @State private var expandedWorkspacePath: String?

    var body: some View {
        VStack(spacing: 0) {
            headerView
            List {
                primaryActionsSection
                projectsSection
                chatsSection
                utilitiesSection
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
        .onChange(of: chatStore.selectedProject) { _, _ in
            // Each collection starts compact. Search can still reveal a result
            // explicitly through openThread(_:), without expanding every list.
            visibleChatLimit = SidebarConversationDisclosure.batchSize
            expandedWorkspacePath = selectedWorkspacePath
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
                expandedWorkspacePath = nil
                visibleChatLimit = SidebarConversationDisclosure.batchSize
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

    // MARK: - Configuration

    /// Configuration destinations follow workspace navigation while remaining
    /// visually separate from project and conversation collections.
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
            sectionHeader("Configuration")
        }
    }

    private enum UtilityItem: CaseIterable {
        case tools
        case skills

        var label: String {
            switch self {
            case .tools: "Tools"
            case .skills: "Profiles"
            }
        }
        var icon: String {
            switch self {
            // Tools is a capability catalog and matrix, so a neutral grid is
            // more faithful than a physical construction or settings metaphor.
            case .tools: return "square.grid.2x2"
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
            // Keep each workspace and its conversations in one source-list group.
            // The selected workspace is the only expanded group, so All Chats can
            // remain a separate global collection without duplicating rows.
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

        return DisclosureGroup(
            isExpanded: workspaceExpansionBinding(for: path)
        ) {
            workspaceChats()
        } label: {
            Button {
                selectWorkspace(path)
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
                    if isActiveWorkspace {
                        // Color.accentColor follows the user's macOS accent choice.
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
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
            .accessibilityValue(isActiveWorkspace ? "Selected workspace" : "")
        }
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

    private func selectWorkspace(_ path: String) {
        chatStore.setRoute(.chat)
        // Sidebar project selection is the single workspace navigation path.
        // Reuse the established transition so model, Git, diffs, recency,
        // and inspector state remain consistent with the former toolbar menu.
        chatStore.switchToWorkspace(path)
        expandedWorkspacePath = path
        visibleChatLimit = SidebarConversationDisclosure.batchSize
    }

    private func workspaceExpansionBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { expandedWorkspacePath == path },
            set: { isExpanded in
                if isExpanded {
                    // Expanding a workspace also selects it, keeping its model
                    // context and nested conversation collection aligned.
                    selectWorkspace(path)
                } else if expandedWorkspacePath == path {
                    expandedWorkspacePath = nil
                }
            }
        )
    }

    @ViewBuilder
    private func workspaceChats() -> some View {
        // DisclosureGroup content is rendered only for the selected workspace,
        // therefore the existing selectedProject filter remains the source of
        // truth for visibility, archive state, search, and ordering.
        chatsContent(indented: true)
    }

    // MARK: - Chats Section

    @ViewBuilder
    private var chatsSection: some View {
        if chatStore.selectedProject == nil {
            Section {
                chatsContent(indented: false)
            } header: {
                sectionHeader("Chats")
            }
        }
    }

    @ViewBuilder
    private func chatsContent(indented: Bool) -> some View {
        if chatStore.sortedThreads.isEmpty {
            emptyChatsView(indented: indented)
        } else {
            chatsList(indented: indented)
        }
    }

    private func emptyChatsView(indented: Bool) -> some View {
        HStack {
            Text("No chats")
                .font(AppTypography.sidebarMetadata)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.leading, indented ? 20 : 0)
        .padding(.vertical, 20)
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func chatsList(indented: Bool) -> some View {
        let sortedThreads = chatStore.sortedThreads
        let visibleThreadIDs = SidebarConversationDisclosure.visibleIDs(
            in: sortedThreads,
            limit: visibleChatLimit
        )

        // Keep ordering and filtering as value snapshots, but resolve each row
        // from the observable store so an asynchronously generated title is
        // immediately reflected without changing the row's stable identity.
        ForEach(visibleThreadIDs, id: \.self) { threadID in
            if let thread = chatStore.threads.first(where: { $0.id == threadID }) {
                threadRow(for: thread)
                    .padding(.leading, indented ? 20 : 0)
                    .listRowInsets(sidebarRowInsets)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }

        if sortedThreads.count > SidebarConversationDisclosure.batchSize {
            chatDisclosureButton(
                totalCount: sortedThreads.count,
                indented: indented
            )
                .listRowInsets(sidebarRowInsets)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    private func chatDisclosureButton(totalCount: Int, indented: Bool) -> some View {
        let remaining = max(0, totalCount - visibleChatLimit)
        let revealsMore = remaining > 0
        let nextBatchCount = min(SidebarConversationDisclosure.batchSize, remaining)

        return Button {
            if revealsMore {
                visibleChatLimit = SidebarConversationDisclosure.nextLimit(
                    current: visibleChatLimit,
                    total: totalCount
                )
            } else {
                visibleChatLimit = SidebarConversationDisclosure.batchSize
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: revealsMore ? "ellipsis" : "chevron.up")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(revealsMore ? "Show \(nextBatchCount) More" : "Show Less")
                    .font(AppTypography.sidebarMetadata)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.leading, indented ? 20 : 0)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(revealsMore ? "Reveal more chats" : "Collapse chats")
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

    private var selectedWorkspacePath: String? {
        guard let selectedProject = chatStore.selectedProject,
              !chatStore.workspaceRoot.isEmpty,
              URL(fileURLWithPath: chatStore.workspaceRoot).lastPathComponent == selectedProject,
              chatStore.recentWorkspaces.contains(chatStore.workspaceRoot) else {
            return nil
        }
        return chatStore.workspaceRoot
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
        visibleChatLimit = SidebarConversationDisclosure.limitRevealing(
            threadID: thread.id,
            in: chatStore.sortedThreads,
            current: visibleChatLimit
        )
        Task {
            // Chat becomes visible only after its final state is ready, avoiding
            // a costly intermediate render of the previously active timeline.
            await chatStore.openThread(thread.id)
        }
    }

}

/// Pure batching policy for the sidebar's progressive chat disclosure. Keeping
/// it independent from SwiftUI state makes the five-row contract reviewable and
/// prevents search results from opening without a visible selected row.
nonisolated enum SidebarConversationDisclosure {
    static let batchSize = 5

    static func visibleIDs(in threads: [Conversation], limit: Int) -> [String] {
        Array(threads.prefix(max(batchSize, limit))).map(\.id)
    }

    static func nextLimit(current: Int, total: Int) -> Int {
        min(total, max(batchSize, current) + batchSize)
    }

    static func limitRevealing(
        threadID: String,
        in threads: [Conversation],
        current: Int
    ) -> Int {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else {
            return current
        }
        let requiredBatch = ((index / batchSize) + 1) * batchSize
        return max(current, requiredBatch)
    }
}
