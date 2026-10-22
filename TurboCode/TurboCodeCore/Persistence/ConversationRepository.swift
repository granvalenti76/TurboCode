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
    let contextProjection: TranscriptContextProjection
    /// Optional usage metadata keeps pre-statistics session files readable.
    let statistics: ComposerSessionStatistics?
    /// Steering is persisted with the conversation, but its provider claim is
    /// never resumed implicitly after a process or context boundary.
    let steering: SteeringQueueSnapshot

    init(
        conversation: Conversation,
        modelBackend: String,
        blocks: [ChatBlock],
        transcript: Transcript?,
        contextProjection: TranscriptContextProjection = .empty,
        steering: SteeringQueueSnapshot = .empty,
        statistics: ComposerSessionStatistics? = nil
    ) {
        self.conversation = conversation
        self.modelBackend = modelBackend
        self.blocks = blocks
        self.transcript = transcript
        self.contextProjection = contextProjection
        self.steering = steering
        self.statistics = statistics
    }

    /// Re-encodes the durable session shape without exposing repository paths
    /// to UI code. Export therefore follows the same schema as persistence.
    nonisolated func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(storedSession)
    }
}

/// One session file that could not be decoded during a catalog scan.
nonisolated struct UnreadableSessionFile: Sendable, Equatable {
    let fileName: String
    let reason: String
}

/// Result of a catalog scan. Unreadable files are reported, never modified,
/// so one corrupt or newer-format file cannot hide every other conversation.
nonisolated struct ConversationCatalogLoad: Sendable {
    let snapshots: [ConversationSnapshot]
    let unreadableSessions: [UnreadableSessionFile]
}

/// Persistence contract for conversations. Keeping this boundary protocol-based
/// lets a host coordinate presentation without knowing where sessions are stored.
nonisolated protocol ConversationRepository: Sendable {
    func save(_ snapshot: ConversationSnapshot) async throws
    func load(id: String) async throws -> ConversationSnapshot?
    /// Readable sessions only; unreadable rows are skipped, not fatal.
    func list() async throws -> [ConversationSnapshot]
    /// Readable sessions plus the files that had to be skipped. Throws only
    /// when the storage location itself cannot be enumerated.
    func loadCatalog() async throws -> ConversationCatalogLoad
    func delete(id: String) async throws
    func append(
        id: String,
        blocks: [ChatBlock],
        transcriptEntries: [Transcript.Entry]
    ) async throws
    /// Replaces catalog metadata while keeping the stored timeline,
    /// transcript, and domain. Implementations must read and write as one
    /// isolated step: a concurrent `append` landing between a separate load
    /// and save would otherwise be overwritten with the older timeline.
    func updateMetadata(
        _ conversation: Conversation,
        defaultModelBackend: String
    ) async throws
}

extension ConversationRepository {
    /// In-memory repositories have no undecodable rows to report.
    func loadCatalog() async throws -> ConversationCatalogLoad {
        ConversationCatalogLoad(snapshots: try await list(), unreadableSessions: [])
    }

    /// Default composition keeps lightweight test repositories source
    /// compatible. It is not atomic; disk storage overrides it as one
    /// actor-isolated update.
    func updateMetadata(
        _ conversation: Conversation,
        defaultModelBackend: String
    ) async throws {
        try await save(
            ConversationSnapshot.mergingMetadata(
                conversation,
                onto: try await load(id: conversation.id),
                defaultModelBackend: defaultModelBackend
            )
        )
    }

    /// Default composition keeps lightweight test repositories source
    /// compatible. Disk storage overrides this as one actor-isolated update.
    func append(
        id: String,
        blocks: [ChatBlock],
        transcriptEntries: [Transcript.Entry]
    ) async throws {
        guard let existing = try await load(id: id) else { return }
        try await save(
            existing.appending(
                blocks: blocks,
                transcriptEntries: transcriptEntries
            )
        )
    }
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
        return try decodeSnapshot(at: url)
    }

    func list() throws -> [ConversationSnapshot] {
        try scanCatalog().snapshots
    }

    /// Declared `async` on purpose: a synchronous actor method would lose
    /// overload resolution to the protocol extension's async default in
    /// `await` call sites, silently dropping the unreadable-file report.
    func loadCatalog() async throws -> ConversationCatalogLoad {
        try scanCatalog()
    }

    /// Decodes every session file independently. A failure is recorded and
    /// the file is left exactly as found: moving or rewriting it here could
    /// destroy a session that a newer TurboCode or a fixed decoder can read.
    private func scanCatalog() throws -> ConversationCatalogLoad {
        try createDirectoryIfNeeded()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var snapshots: [ConversationSnapshot] = []
        var unreadable: [UnreadableSessionFile] = []
        for url in urls {
            do {
                snapshots.append(try decodeSnapshot(at: url))
            } catch {
                print("[TurboCode] Skipped unreadable session \(url.lastPathComponent): \(error)")
                unreadable.append(
                    UnreadableSessionFile(
                        fileName: url.lastPathComponent,
                        reason: error.localizedDescription
                    )
                )
            }
        }
        return ConversationCatalogLoad(
            snapshots: snapshots,
            unreadableSessions: unreadable
        )
    }

    func delete(id: String) throws {
        let url = try fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Load, merge, and atomic replacement stay inside the repository actor so
    /// an inactive thread cannot lose a completion to an overlapping save.
    /// `async` (with no suspension inside) makes this override win overload
    /// resolution against the non-atomic protocol extension default.
    func append(
        id: String,
        blocks: [ChatBlock],
        transcriptEntries: [Transcript.Entry]
    ) async throws {
        guard let existing = try load(id: id) else { return }
        try save(
            existing.appending(
                blocks: blocks,
                transcriptEntries: transcriptEntries
            )
        )
    }

    /// Same isolation rule as `append`: there is no suspension point between
    /// reading the stored session and replacing it. An unreadable file makes
    /// `load` throw, so it is never rewritten with an empty timeline.
    func updateMetadata(
        _ conversation: Conversation,
        defaultModelBackend: String
    ) async throws {
        try save(
            ConversationSnapshot.mergingMetadata(
                conversation,
                onto: try load(id: conversation.id),
                defaultModelBackend: defaultModelBackend
            )
        )
    }

    /// Shared by single loads and catalog scans so both apply the same
    /// recovery rules. Recovered provider fields are logged because the next
    /// save replaces them with the rebuilt, timeline-derived history.
    private func decodeSnapshot(at url: URL) throws -> ConversationSnapshot {
        let stored = try JSONDecoder().decode(
            StoredSession.self,
            from: Data(contentsOf: url)
        )
        if !stored.recoveredFields.isEmpty {
            print(
                "[TurboCode] Session \(stored.id): discarded undecodable "
                    + stored.recoveredFields.joined(separator: ", ")
            )
        }
        return ConversationSnapshot(stored)
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

private extension ConversationSnapshot {
    nonisolated func appending(
        blocks newBlocks: [ChatBlock],
        transcriptEntries: [Transcript.Entry]
    ) -> ConversationSnapshot {
        var updatedConversation = conversation
        updatedConversation.updatedAt = .now
        let updatedTranscript: Transcript?
        if let transcript {
            updatedTranscript = Transcript(
                entries: Array(transcript) + transcriptEntries
            )
        } else if !transcriptEntries.isEmpty {
            // A background completion can be the first portable provider
            // context persisted for a lightweight or migrated conversation.
            updatedTranscript = Transcript(entries: transcriptEntries)
        } else {
            updatedTranscript = nil
        }
        return ConversationSnapshot(
            conversation: updatedConversation,
            modelBackend: modelBackend,
            blocks: blocks + newBlocks,
            transcript: updatedTranscript,
            contextProjection: contextProjection,
            steering: steering,
            statistics: statistics
        )
    }
}

private extension ConversationSnapshot {
    /// Applies catalog metadata (title, pin, archive, mode, workspace) to the
    /// stored session. The persisted domain wins over the caller's value: a
    /// metadata edit built from a default-initialized Conversation must never
    /// turn a Cowork session into a Coding session with host tools.
    nonisolated static func mergingMetadata(
        _ conversation: Conversation,
        onto existing: ConversationSnapshot?,
        defaultModelBackend: String
    ) -> ConversationSnapshot {
        let persistedDomain = existing?.conversation.domain ?? conversation.domain
        return ConversationSnapshot(
            conversation: conversation.withDomain(persistedDomain),
            modelBackend: existing?.modelBackend ?? defaultModelBackend,
            blocks: existing?.blocks ?? [],
            transcript: existing?.transcript,
            contextProjection: existing?.contextProjection ?? .empty,
            steering: existing?.steering ?? .empty,
            statistics: existing?.statistics
        )
    }
}

private extension Conversation {
    /// `domain` is immutable on `Conversation`, so the persistence layer
    /// rebuilds the value when it restores the stored domain. Keep this list in
    /// sync with `Conversation`'s stored properties.
    nonisolated func withDomain(_ domain: SessionDomain) -> Conversation {
        guard domain != self.domain else { return self }
        return Conversation(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isPinned: isPinned,
            isArchived: isArchived,
            workspace: workspace,
            mode: mode,
            domain: domain,
            coworkFolder: coworkFolder
        )
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
            mode: stored.mode,
            domain: stored.domain,
            coworkFolder: stored.coworkFolder
        )
        modelBackend = stored.modelBackend
        blocks = stored.blocks.map(ChatBlock.init)
        transcript = stored.transcript
        contextProjection = stored.contextProjection
        steering = stored.steering
        statistics = stored.statistics
    }

    nonisolated var storedSession: StoredSession {
        var storedSession = StoredSession(
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
            domain: conversation.domain,
            modelBackend: modelBackend,
            blocks: blocks.map(StoredBlock.init),
            transcript: transcript,
            contextProjection: contextProjection,
            steering: steering
        )
        storedSession.statistics = statistics
        storedSession.coworkFolder = conversation.coworkFolder
        return storedSession
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
