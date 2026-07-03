import Foundation
import Observation
import SwiftUI

// MARK: - Central ChatStore (replaces Zustand store)

@MainActor
@Observable
public final class ChatStore {
    // Threads
    public var threads: [Thread] = []
    public var activeThreadId: String?
    public var threadSearch: String = ""
    public var showArchivedThreads: Bool = false

    // Timeline
    public var blocks: [ChatBlock] = []
    public var liveReasoning: String = ""
    public var liveAssistant: String = ""

    // Composer
    public var composerModel: String = "auto"
    public var composerProviderId: String = ""
    public var composerMode: ThreadMode = .agent
    public var composerInput: String = ""
    public var composerAttachments: Int = 0

    // Runtime
    public var runtimeStatus: RuntimeStatus = .disconnected
    public var runtimeConnection: RuntimeConnectionState = .disconnected
    public var busy: Bool = false
    public var error: String?

    // Navigation
    public var route: AppRoute = .chat
    public var settingsSection: SettingsSection = .general

    // Sidebar
    public var leftSidebarCollapsed: Bool = false
    public var leftSidebarWidth: CGFloat = 304

    // Right panel
    public var rightPanelMode: RightPanelMode?
    public var rightPanelVisible: Bool { rightPanelMode != nil }
    public var rightSidebarWidth: CGFloat = 360

    // Terminal
    public var terminalOpen: Bool = false
    public var terminalHeight: CGFloat = 360

    // MARK: - Actions

    public func selectThread(_ id: String) async {
        activeThreadId = id
        // TODO: load blocks from runtime
    }

    public func createThread(title: String = "New Chat", mode: ThreadMode = .agent) async {
        let thread = Thread(title: title, mode: mode)
        threads.insert(thread, at: 0)
        activeThreadId = thread.id
    }

    public func renameThread(id: String, title: String) async {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].title = title
        threads[index].updatedAt = .now
    }

    public func pinThread(id: String, pinned: Bool) async {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].isPinned = pinned
        threads[index].updatedAt = .now
    }

    public func archiveThread(id: String) async {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].isArchived = true
        threads[index].updatedAt = .now
    }

    public func deleteThread(id: String) async {
        threads.removeAll { $0.id == id }
        if activeThreadId == id { activeThreadId = threads.first?.id }
    }

    public func restoreThread(id: String) async {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].isArchived = false
        threads[index].updatedAt = .now
    }

    public func sendMessage(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let userBlock = ChatBlock(kind: .user, text: text)
        blocks.append(userBlock)

        let placeholder = ChatBlock(kind: .assistant, text: "", model: composerModel)
        blocks.append(placeholder)

        busy = true
        // TODO: send to Kun runtime via HTTP/SSE
    }

    public func interrupt() {
        // TODO: interrupt current streaming
        busy = false
    }

    public func setRoute(_ route: AppRoute) {
        self.route = route
        if route != .chat {
            rightPanelMode = nil
        }
    }

    public func toggleRightPanel(_ mode: RightPanelMode) {
        if rightPanelMode == mode {
            rightPanelMode = nil
        } else {
            rightPanelMode = mode
        }
    }

    public func toggleTerminal() {
        terminalOpen.toggle()
    }

    public func toggleLeftSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            leftSidebarCollapsed.toggle()
        }
    }

    /// Ordered list of threads for the sidebar (pinned first, then by updatedAt)
    public var sortedThreads: [Thread] {
        let searchQuery = threadSearch.lowercased().trimmingCharacters(in: .whitespaces)
        let filtered = threads.filter { thread in
            if showArchivedThreads { return true }
            return !thread.isArchived
        }.filter { thread in
            guard !searchQuery.isEmpty else { return true }
            return thread.title.lowercased().contains(searchQuery)
        }
        return filtered.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.updatedAt > b.updatedAt
        }
    }
}

// MARK: - Runtime status

public enum RuntimeStatus: String, Sendable, Hashable {
    case disconnected
    case connecting
    case ready
    case error
}

public enum RuntimeConnectionState: String, Sendable, Hashable {
    case disconnected
    case connecting
    case ready
}
