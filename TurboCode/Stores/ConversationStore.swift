import Foundation
import Observation

/// Owns the conversation catalog and its persistence boundary.
///
/// ChatStore remains responsible for coordinating a selected conversation with
/// the model session and visible timeline. Keeping those runtime transitions
/// outside this store prevents catalog mutations from implicitly rebuilding a
/// model or discarding in-flight output.
@MainActor
@Observable
final class ConversationStore {
    var threads: [Conversation] = []
    var activeThreadID: String?
    var search: String = ""
    var showsArchivedThreads = false

    private let repository: any ConversationRepository

    init(repository: any ConversationRepository) {
        self.repository = repository
    }

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

    func persist(_ snapshot: ConversationSnapshot) throws {
        try repository.save(snapshot)
    }

    /// Updates durable catalog metadata without loading the thread's timeline
    /// into the active UI. This keeps rename, pin, and archive actions safe for
    /// inactive conversations while preserving their original runtime state.
    func persistMetadata(id: String) throws {
        guard let conversation = threads.first(where: { $0.id == id }) else { return }
        let existing = try repository.load(id: id)
        let snapshot = ConversationSnapshot(
            conversation: conversation,
            modelBackend: existing?.modelBackend ?? ModelBackend.foundationApple.rawValue,
            blocks: existing?.blocks ?? [],
            transcript: existing?.transcript
        )
        try repository.save(snapshot)
    }

    /// Merges durable sessions without duplicating drafts already present in
    /// memory, such as a thread created during application startup.
    func restoreCatalog() throws {
        let snapshots = try repository.list()
        guard !snapshots.isEmpty else { return }
        let existingIDs = Set(threads.map(\.id))
        threads.append(
            contentsOf: snapshots
                .map(\.conversation)
                .filter { !existingIDs.contains($0.id) }
        )
    }

    func snapshot(id: String) throws -> ConversationSnapshot? {
        try repository.load(id: id)
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

    /// Deletes durable data before mutating the observable catalog. This
    /// ordering ensures a failed filesystem operation cannot appear successful
    /// until the next application launch.
    func deleteThread(id: String) throws -> String? {
        try repository.delete(id: id)
        threads.removeAll { $0.id == id }
        if activeThreadID == id {
            activeThreadID = nil
        }
        return threads.first?.id
    }

    /// Deletes every persisted conversation associated with a workspace while
    /// leaving the workspace directory itself untouched.
    func removeWorkspace(_ path: String) -> WorkspaceConversationRemoval {
        var sessionIDs = Set(
            threads
                .filter { $0.workspace == path }
                .map(\.id)
        )
        if let storedSessions = try? repository.list() {
            sessionIDs.formUnion(
                storedSessions
                    .filter { $0.conversation.workspace == path }
                    .map(\.conversation.id)
            )
        }

        var deletionErrors: [String] = []
        for id in sessionIDs {
            do {
                try repository.delete(id: id)
            } catch {
                deletionErrors.append(error.localizedDescription)
            }
        }

        let removedActiveThread = activeThreadID.map(sessionIDs.contains) ?? false
        threads.removeAll { $0.workspace == path }
        if removedActiveThread {
            activeThreadID = nil
        }
        return WorkspaceConversationRemoval(
            removedActiveThread: removedActiveThread,
            deletionErrors: deletionErrors
        )
    }

    func sortedThreads(selectedProject: String?) -> [Conversation] {
        let query = search.lowercased().trimmingCharacters(in: .whitespaces)
        return threads
            .filter { showsArchivedThreads || !$0.isArchived }
            .filter { thread in
                guard let selectedProject else { return true }
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

/// Workspace cleanup outcome consumed by ChatStore to reset runtime state and
/// report partial persistence failures.
struct WorkspaceConversationRemoval {
    let removedActiveThread: Bool
    let deletionErrors: [String]
}
