import Foundation

/// Domain snapshot used at the persistence boundary.
struct ConversationSnapshot: Sendable {
    let conversation: Conversation
    let modelBackend: String
    let blocks: [ChatBlock]
}

/// Persistence contract for conversations. Keeping this boundary protocol-based
/// lets ChatStore coordinate UI state without knowing where sessions are stored.
protocol ConversationRepository: Sendable {
    func save(_ snapshot: ConversationSnapshot) throws
    func load(id: String) throws -> ConversationSnapshot?
    func list() throws -> [ConversationSnapshot]
    func delete(id: String) throws
}

struct DiskConversationRepository: ConversationRepository {
    func save(_ snapshot: ConversationSnapshot) throws {
        try TurboCodeConfig.shared.saveSession(snapshot.storedSession)
    }

    func load(id: String) throws -> ConversationSnapshot? {
        try TurboCodeConfig.shared.loadSession(id: id).map(ConversationSnapshot.init)
    }

    func list() throws -> [ConversationSnapshot] {
        try TurboCodeConfig.shared.listSessions().map(ConversationSnapshot.init)
    }

    func delete(id: String) throws {
        try TurboCodeConfig.shared.deleteSession(id: id)
    }
}

private extension ConversationSnapshot {
    init(_ stored: StoredSession) {
        conversation = Conversation(
            id: stored.id,
            title: stored.title,
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt,
            workspace: stored.workspacePath,
            mode: .agent
        )
        modelBackend = stored.modelBackend
        blocks = stored.blocks.map(ChatBlock.init)
    }

    var storedSession: StoredSession {
        StoredSession(
            id: conversation.id,
            title: conversation.title,
            projectName: conversation.workspace
                .flatMap { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "_general",
            workspacePath: conversation.workspace,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            modelBackend: modelBackend,
            blocks: blocks.map(StoredBlock.init)
        )
    }
}

private extension ChatBlock {
    init(_ stored: StoredBlock) {
        self.init(
            id: stored.id,
            kind: ChatBlockKind(rawValue: stored.kind) ?? .assistant,
            text: stored.text,
            createdAt: stored.createdAt,
            model: stored.model,
            providerId: stored.providerId,
            diffPatch: stored.diffPatch,
            gitCommit: stored.gitCommit
        )
    }
}

private extension StoredBlock {
    init(_ block: ChatBlock) {
        self.init(
            id: block.id,
            kind: block.kind.rawValue,
            text: block.text,
            createdAt: block.createdAt,
            model: block.model,
            providerId: block.providerId,
            diffPatch: block.diffPatch,
            gitCommit: block.gitCommit
        )
    }
}
