import Foundation
import Observation

/// Owns the observable conversation catalog.
///
/// Persistence and runtime transitions are deliberately external: this store
/// performs synchronous MVVM mutations only, so observing the sidebar can never
/// trigger disk I/O or model-session work.
@MainActor
@Observable
final class ConversationStore {
    var threads: [Conversation] = []
    var activeThreadID: String?
    var search: String = ""
    var showsArchivedThreads = false

    /// Inserts a new active catalog entry. ChatStore initializes the matching
    /// empty timeline and model session as one separate coordinated transition.
    @discardableResult
    func createThread(
        title: String,
        workspace: String?,
        mode: ConversationMode
    ) -> Conversation {
        let thread = Conversation(title: title, workspace: workspace, mode: mode)
        threads.insert(thread, at: 0)
        activeThreadID = thread.id
        return thread
    }

    /// Creates missing metadata for message entry points that have no valid
    /// active thread. Returning whether creation occurred lets ChatStore decide
    /// whether orphaned visible blocks must be preserved.
    @discardableResult
    func ensureActiveThread(
        workspace: String?,
        mode: ConversationMode
    ) -> Bool {
        guard let activeThreadID,
              threads.contains(where: { $0.id == activeThreadID }) else {
            createThread(title: "New Chat", workspace: workspace, mode: mode)
            return true
        }
        return false
    }

    /// Applies generated titles only to untouched drafts. Stable identity and
    /// the title guard prevent delayed inference from overwriting manual edits.
    func applyGeneratedTitle(_ title: String, to threadID: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }),
              threads[index].title == "New Chat" else { return }
        threads[index].title = title
        threads[index].updatedAt = .now
    }

    /// Merges durable sessions without duplicating drafts already present in
    /// memory, such as a thread created during application startup.
    func restoreCatalog(_ conversations: [Conversation]) {
        guard !conversations.isEmpty else { return }
        let existingIDs = Set(threads.map(\.id))
        threads.append(
            contentsOf: conversations
                .filter { !existingIDs.contains($0.id) }
        )
    }

    func conversation(id: String) -> Conversation? {
        threads.first { $0.id == id }
    }

    func renameThread(id: String, title: String) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].title = title
        threads[index].updatedAt = .now
    }

    func pinThread(id: String, pinned: Bool) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].isPinned = pinned
        threads[index].updatedAt = .now
    }

    func archiveThread(id: String) {
        setArchived(true, for: id)
    }

    func restoreThread(id: String) {
        setArchived(false, for: id)
    }

    /// Marks activity by stable identity so streaming completion cannot update
    /// a different row after catalog ordering or navigation changes.
    func touchThread(id: String) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].updatedAt = .now
    }

    /// Applies a deletion only after the persistence use case succeeds.
    func removeThread(id: String) -> String? {
        threads.removeAll { $0.id == id }
        if activeThreadID == id {
            activeThreadID = nil
        }
        return threads.first?.id
    }

    /// Applies only repository-confirmed removals. A failed durable deletion
    /// remains visible rather than disappearing until the next app launch.
    func removeThreads(ids: Set<String>) -> Bool {
        let removedActiveThread = activeThreadID.map(ids.contains) ?? false
        threads.removeAll { ids.contains($0.id) }
        if removedActiveThread {
            activeThreadID = nil
        }
        return removedActiveThread
    }

    func sortedThreads(selectedProject: String?) -> [Conversation] {
        let query = search.lowercased().trimmingCharacters(in: .whitespaces)
        return threads
            .filter { showsArchivedThreads || !$0.isArchived }
            .filter { thread in
                guard let selectedProject else {
                    // The global Chats section is reserved for conversations
                    // with no workspace; project-bound sessions are rendered
                    // only inside their workspace disclosure group.
                    return thread.workspace == nil
                }
                return thread.workspace.flatMap {
                    URL(fileURLWithPath: $0).lastPathComponent
                } == selectedProject
            }
            .filter { query.isEmpty || $0.title.lowercased().contains(query) }
            .sorted { first, second in
                if first.isPinned != second.isPinned { return first.isPinned }
                return first.updatedAt > second.updatedAt
            }
    }

    private func setArchived(_ isArchived: Bool, for id: String) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].isArchived = isArchived
        threads[index].updatedAt = .now
    }
}
