import SwiftUI

// MARK: - SidebarView — macOS native sidebar with thread list, search, and actions

struct SidebarView: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            sidebarHeader

            Divider()

            // Section tabs: Conversations / Projects
            WorkspaceModePickerView(
                activeView: Binding(
                    get: { chatStore.route },
                    set: { chatStore.setRoute($0) }
                )
            )

            // Search field
            searchField
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            // Thread list
            threadList
        }
        .background(.background)
    }

    // MARK: - Header

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .opacity(0)

            Spacer()

            Text("Conversations")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            Button {
                Task { await chatStore.createThread() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("New Chat")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onChange(of: searchText) { _, newValue in
                    chatStore.threadSearch = newValue
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    chatStore.threadSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Thread List

    private var threadList: some View {
        List(chatStore.sortedThreads) { thread in
            ThreadRowView(
                thread: thread,
                isSelected: thread.id == chatStore.activeThreadId,
                onSelect: {
                    Task { await chatStore.selectThread(thread.id) }
                },
                onRename: { newTitle in
                    Task { await chatStore.renameThread(id: thread.id, title: newTitle) }
                },
                onPin: {
                    Task { await chatStore.pinThread(id: thread.id, pinned: !thread.isPinned) }
                },
                onArchive: {
                    Task { await chatStore.archiveThread(id: thread.id) }
                },
                onDelete: {
                    Task { await chatStore.deleteThread(id: thread.id) }
                },
                onRestore: {
                    Task { await chatStore.restoreThread(id: thread.id) }
                }
            )
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - WorkspaceModePickerView — tab-like picker for sidebar sections

struct WorkspaceModePickerView: View {
    @Binding var activeView: AppRoute

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SidebarTab.allCases, id: \.self) { tab in
                Button {
                    activeView = tab.route
                } label: {
                    Label(tab.label, systemImage: tab.icon)
                        .font(.system(size: 11))
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderless)
                .help(tab.label)
                .background(
                    activeView == tab.route
                        ? Color.accentColor.opacity(0.1)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .foregroundStyle(activeView == tab.route ? Color.accentColor : .secondary)
            }
        }
        .padding(4)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

private enum SidebarTab: String, CaseIterable {
    case chat
    case write
    case claw
    case schedule
    case workflow

    var route: AppRoute {
        switch self {
        case .chat: return .chat
        case .write: return .write
        case .claw: return .claw
        case .schedule: return .schedule
        case .workflow: return .workflow
        }
    }

    var label: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .chat: return "message"
        case .write: return "pencil"
        case .claw: return "antenna.radiowaves.left.and.right"
        case .schedule: return "clock"
        case .workflow: return "square.grid.2x2"
        }
    }
}
