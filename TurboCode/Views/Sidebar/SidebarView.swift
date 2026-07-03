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
            // Footer — user profile
            footerView
        }
        .background(Color(.windowBackgroundColor))
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
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
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
                            .font(.system(size: 12))
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
                    .background(
                        selectedNav == item.id
                            ? .quaternary.opacity(0.3)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
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

            ForEach(ProjectItem.allCases, id: \.self) { project in
                Button {
                    // TODO: select project
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(width: 16)
                        Text(project.label)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                        Spacer()
                        if let badge = project.badge {
                            Text(badge)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private enum ProjectItem: String, CaseIterable {
        case esempiUI = "EsempiUI"
        case gemmaChat = "gemma-chat"
        case articoli = "Articoli"
        case blog = "blog"
        case apostrophe = "Apostrophe"
        case mimic = "Mimic"
        case codechat = "Codechat"
        case ciao = "  Ciao"

        var label: String {
            if self == .ciao { return "   Ciao" }
            return rawValue
        }
        var badge: String? {
            self == .ciao ? "1w" : nil
        }
    }

    // MARK: - Chats Section

    private var chatsSection: some View {
        VStack(spacing: 0) {
            sectionHeader("Chats")

            if chatStore.threads.isEmpty {
                HStack {
                    Text("No chats")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 20)
            } else {
                ForEach(chatStore.sortedThreads.prefix(10)) { thread in
                    ThreadRowView(
                        thread: thread,
                        isSelected: thread.id == chatStore.activeThreadId,
                        onSelect: { Task { await chatStore.selectThread(thread.id) } },
                        onRename: { Task { await chatStore.renameThread(id: thread.id, title: $0) } },
                        onPin: { Task { await chatStore.pinThread(id: thread.id, pinned: !thread.isPinned) } },
                        onArchive: { Task { await chatStore.archiveThread(id: thread.id) } },
                        onDelete: { Task { await chatStore.deleteThread(id: thread.id) } },
                        onRestore: { Task { await chatStore.restoreThread(id: thread.id) } }
                    )
                }
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(Color(red: 0.5, green: 0.3, blue: 0.8))
                        .frame(width: 28, height: 28)
                    Text("L")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("luca.trav@gm...")
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Text("Free")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button("Update") {}
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 8))

                Button("Upgrade") {}
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0.5, green: 0.3, blue: 0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}
