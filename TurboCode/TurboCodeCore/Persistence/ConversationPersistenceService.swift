import Foundation

/// Application-facing persistence use cases built on the storage port.
///
/// This value owns no observable state and never hops to `MainActor`. UI stores
/// pass immutable domain values in and apply returned values only after awaited
/// I/O completes, keeping disk latency out of presentation ownership.
nonisolated struct ConversationPersistenceService: Sendable {
    private let repository: any ConversationRepository

    init(repository: any ConversationRepository) {
        self.repository = repository
    }

    func save(_ snapshot: ConversationSnapshot) async throws {
        try await repository.save(snapshot)
    }

    /// Rewrites catalog metadata while preserving the durable timeline and
    /// transcript. This is essential for inactive conversations, whose content
    /// must never be replaced with whichever timeline is currently visible.
    func saveMetadata(
        _ conversation: Conversation,
        defaultModelBackend: String
    ) async throws {
        let existing = try await repository.load(id: conversation.id)
        let snapshot = ConversationSnapshot(
            conversation: conversation,
            modelBackend: existing?.modelBackend ?? defaultModelBackend,
            blocks: existing?.blocks ?? [],
            transcript: existing?.transcript
        )
        try await repository.save(snapshot)
    }

    func loadCatalog() async throws -> [Conversation] {
        try await repository.list().map(\.conversation)
    }

    func load(id: String) async throws -> ConversationSnapshot? {
        try await repository.load(id: id)
    }

    func delete(id: String) async throws {
        try await repository.delete(id: id)
    }

    /// Deletes every durable conversation associated with a workspace. IDs
    /// already visible in the host are included even when catalog enumeration
    /// fails, and only successful deletions are returned for UI removal.
    func removeWorkspace(
        _ path: String,
        visibleConversations: [Conversation]
    ) async -> WorkspacePersistenceRemoval {
        var sessionIDs = Set(
            visibleConversations
                .filter { $0.workspace == path }
                .map(\.id)
        )
        var deletionErrors: [String] = []

        do {
            sessionIDs.formUnion(
                try await repository.list()
                    .filter { $0.conversation.workspace == path }
                    .map(\.conversation.id)
            )
        } catch {
            deletionErrors.append("Could not enumerate persisted chats: \(error.localizedDescription)")
        }

        var deletedConversationIDs: Set<String> = []
        for id in sessionIDs.sorted() {
            do {
                try await repository.delete(id: id)
                deletedConversationIDs.insert(id)
            } catch {
                deletionErrors.append("\(id): \(error.localizedDescription)")
            }
        }

        return WorkspacePersistenceRemoval(
            deletedConversationIDs: deletedConversationIDs,
            deletionErrors: deletionErrors
        )
    }
}

/// Result applied by a host after durable workspace cleanup completes.
/// Failed IDs are deliberately absent from `deletedConversationIDs`, ensuring
/// their visible rows remain honest about the state that will survive relaunch.
nonisolated struct WorkspacePersistenceRemoval: Sendable, Equatable {
    let deletedConversationIDs: Set<String>
    let deletionErrors: [String]
}
