import Foundation
import FoundationModels

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
    /// The merge runs inside the repository so it is atomic with respect to
    /// background `append` calls; see `ConversationRepository.updateMetadata`.
    func saveMetadata(
        _ conversation: Conversation,
        defaultModelBackend: String
    ) async throws {
        try await repository.updateMetadata(
            conversation,
            defaultModelBackend: defaultModelBackend
        )
    }

    /// Readable conversations plus the number of session files that were
    /// skipped, so the host can say that history exists but could not open.
    func loadCatalog() async throws -> ConversationCatalog {
        let load = try await repository.loadCatalog()
        return ConversationCatalog(
            conversations: load.snapshots.map(\.conversation),
            unreadableSessions: load.unreadableSessions
        )
    }

    func load(id: String) async throws -> ConversationSnapshot? {
        try await repository.load(id: id)
    }

    /// Delivers application-owned background work to its durable origin even
    /// when another conversation currently owns the visible timeline.
    func append(
        id: String,
        blocks: [ChatBlock],
        transcriptEntries: [Transcript.Entry]
    ) async throws {
        try await repository.append(
            id: id,
            blocks: blocks,
            transcriptEntries: transcriptEntries
        )
    }

    /// Loads exportable session JSON through the repository boundary. Missing
    /// rows are skipped because a newly-created draft can exist in the catalog
    /// before its first durable checkpoint.
    func exportJSON(ids: [String]) async throws -> [ConversationExportItem] {
        var exports: [ConversationExportItem] = []
        for id in ids {
            guard let snapshot = try await repository.load(id: id) else { continue }
            exports.append(
                ConversationExportItem(
                    id: id,
                    title: snapshot.conversation.title,
                    data: try snapshot.encodedJSON()
                )
            )
        }
        return exports
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

/// Catalog metadata applied by the host after the durable scan completes.
nonisolated struct ConversationCatalog: Sendable {
    let conversations: [Conversation]
    let unreadableSessions: [UnreadableSessionFile]
}

/// JSON payload prepared for the sidebar's native export actions.
nonisolated struct ConversationExportItem: Sendable {
    let id: String
    let title: String
    let data: Data

    var suggestedFileName: String {
        let titlePart = Self.safeFileComponent(title, fallback: "conversation")
        let idPart = Self.safeFileComponent(id, fallback: "session")
        return "\(titlePart)-\(idPart).json"
    }

    private static func safeFileComponent(_ value: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let sanitized = value.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? fallback : sanitized
    }
}

/// Result applied by a host after durable workspace cleanup completes.
/// Failed IDs are deliberately absent from `deletedConversationIDs`, ensuring
/// their visible rows remain honest about the state that will survive relaunch.
nonisolated struct WorkspacePersistenceRemoval: Sendable, Equatable {
    let deletedConversationIDs: Set<String>
    let deletionErrors: [String]
}
