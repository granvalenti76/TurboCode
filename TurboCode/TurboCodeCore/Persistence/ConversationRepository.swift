import Foundation
import FoundationModels

/// Domain snapshot used at the persistence boundary. This remains internal
/// while 0.3.7 proves the contract; the eventual package will expose it only
/// after schema compatibility and migration policy are declared stable.
nonisolated struct ConversationSnapshot: Sendable {
    let conversation: Conversation
    let modelBackend: String
    let blocks: [ChatBlock]
    let transcript: Transcript?
    /// Steering is persisted with the conversation, but its provider claim is
    /// never resumed implicitly after a process or context boundary.
    let steering: SteeringQueueSnapshot

    init(
        conversation: Conversation,
        modelBackend: String,
        blocks: [ChatBlock],
        transcript: Transcript?,
        steering: SteeringQueueSnapshot = .empty
    ) {
        self.conversation = conversation
        self.modelBackend = modelBackend
        self.blocks = blocks
        self.transcript = transcript
        self.steering = steering
    }

    /// Re-encodes the durable session shape without exposing repository paths
    /// to UI code. Export therefore follows the same schema as persistence.
    nonisolated func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(storedSession)
    }
}

/// Persistence contract for conversations. Keeping this boundary protocol-based
/// lets a host coordinate presentation without knowing where sessions are stored.
nonisolated protocol ConversationRepository: Sendable {
    func save(_ snapshot: ConversationSnapshot) async throws
    func load(id: String) async throws -> ConversationSnapshot?
    func list() async throws -> [ConversationSnapshot]
    func delete(id: String) async throws
}

/// Serializes session-file access away from MainActor presentation state.
/// `Data.write(.atomic)` remains the durable replacement primitive, while actor
/// isolation prevents overlapping saves, catalog scans, and deletions from
/// racing over the same `~/.turbocode/sessions` directory.
actor DiskConversationRepository: ConversationRepository {
    private let directoryURL: URL

    init(
        directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".turbocode/sessions", isDirectory: true)
    ) {
        self.directoryURL = directoryURL
    }

    func save(_ snapshot: ConversationSnapshot) throws {
        try createDirectoryIfNeeded()
        let data = try encoder.encode(snapshot.storedSession)
        try data.write(to: fileURL(for: snapshot.conversation.id), options: .atomic)
    }

    func load(id: String) throws -> ConversationSnapshot? {
        let url = try fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stored = try JSONDecoder().decode(
            StoredSession.self,
            from: Data(contentsOf: url)
        )
        return ConversationSnapshot(stored)
    }

    func list() throws -> [ConversationSnapshot] {
        try createDirectoryIfNeeded()
        return try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .map { url in
            let stored = try JSONDecoder().decode(
                StoredSession.self,
                from: Data(contentsOf: url)
            )
            return ConversationSnapshot(stored)
        }
    }

    func delete(id: String) throws {
        let url = try fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return value
    }

    private func createDirectoryIfNeeded() throws {
        guard !FileManager.default.fileExists(atPath: directoryURL.path) else {
            return
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    /// Session IDs become filenames. Rejecting path syntax here preserves the
    /// repository boundary even if a future importer supplies external JSON.
    private func fileURL(for id: String) throws -> URL {
        guard !id.isEmpty,
              !id.contains("/"),
              !id.contains("\\"),
              id != ".",
              id != ".." else {
            throw ConversationRepositoryError.invalidSessionID(id)
        }
        return directoryURL.appendingPathComponent("\(id).json")
    }
}

nonisolated enum ConversationRepositoryError: Error, Equatable, Sendable {
    case invalidSessionID(String)
}

private extension ConversationSnapshot {
    nonisolated init(_ stored: StoredSession) {
        conversation = Conversation(
            id: stored.id,
            title: stored.title,
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt,
            isPinned: stored.isPinned,
            isArchived: stored.isArchived,
            workspace: stored.workspacePath,
            mode: stored.mode
        )
        modelBackend = stored.modelBackend
        blocks = stored.blocks.map(ChatBlock.init)
        transcript = stored.transcript
        steering = stored.steering
    }

    nonisolated var storedSession: StoredSession {
        StoredSession(
            id: conversation.id,
            title: conversation.title,
            projectName: conversation.workspace
                .flatMap { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "_general",
            workspacePath: conversation.workspace,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            isPinned: conversation.isPinned,
            isArchived: conversation.isArchived,
            mode: conversation.mode,
            modelBackend: modelBackend,
            blocks: blocks.map(StoredBlock.init),
            transcript: transcript,
            steering: steering
        )
    }
}

private extension ChatBlock {
    nonisolated init(_ stored: StoredBlock) {
        self.init(
            id: stored.id,
            kind: ChatBlockKind(rawValue: stored.kind) ?? .assistant,
            text: stored.text,
            createdAt: stored.createdAt,
            model: stored.model,
            providerId: stored.providerId,
            diffPatch: stored.diffPatch,
            gitCommit: stored.gitCommit,
            gitStatus: stored.gitStatus,
            productGuide: stored.productGuide,
            workspaceListing: stored.workspaceListing,
            pluginWidget: stored.pluginWidget,
            editorialPublication: stored.editorialPublication
        )
        steeringDelivery = stored.steeringDelivery
    }
}

private extension StoredBlock {
    nonisolated init(_ block: ChatBlock) {
        var stored = StoredBlock(
            id: block.id,
            kind: block.kind.rawValue,
            text: block.text,
            createdAt: block.createdAt,
            model: block.model,
            providerId: block.providerId,
            diffPatch: block.diffPatch,
            gitCommit: block.gitCommit,
            gitStatus: block.gitStatus,
            productGuide: block.productGuide,
            workspaceListing: block.workspaceListing,
            pluginWidget: block.pluginWidget,
            editorialPublication: block.editorialPublication
        )
        stored.steeringDelivery = block.steeringDelivery
        self = stored
    }
}
