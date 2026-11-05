import Foundation
import FoundationModels

/// Outcome of loading one durable conversation. `missing` and `unreadable`
/// must stay distinct: a missing file is a draft that may safely start empty,
/// while an unreadable file still holds history that a save would destroy.
enum ConversationLoadResult {
    case loaded(ConversationSnapshot)
    case missing
    case unreadable(reason: String)
}

/// Bridges MainActor conversation projections to UI-neutral persistence use
/// cases. The lifecycle coordinator consumes its immutable load/delete results;
/// this type owns snapshot plumbing and never mutates runtime presentation.
@MainActor
final class ConversationSessionCoordinator {
    private let conversations: ConversationStore
    private let timeline: ChatTimelineStore
    private let modelRuntime: ModelRuntimeStore
    private let llmRuntime: LLMRuntime
    private let runtime: AgentRuntime
    private let persistence: ConversationPersistenceService
    private let statistics: ComposerSessionStatisticsStore
    /// Sessions whose file exists but failed to decode in this process. Every
    /// write path refuses these IDs, so no lifecycle fallback can replace a
    /// recoverable file with the empty timeline that is currently visible.
    private var unreadableSessionIDs: Set<String> = []

    init(
        conversations: ConversationStore,
        timeline: ChatTimelineStore,
        modelRuntime: ModelRuntimeStore,
        llmRuntime: LLMRuntime,
        runtime: AgentRuntime,
        persistence: ConversationPersistenceService,
        statistics: ComposerSessionStatisticsStore
    ) {
        self.conversations = conversations
        self.timeline = timeline
        self.modelRuntime = modelRuntime
        self.llmRuntime = llmRuntime
        self.runtime = runtime
        self.persistence = persistence
        self.statistics = statistics
    }

    /// Value checkpoint used by context policies that must inspect the active
    /// Foundation Models history without retaining its owning session runtime.
    func foundationModelsTranscript() async -> Transcript? {
        await llmRuntime.foundationModelsTranscript()
    }

    func foundationModelsCanonicalTranscript() async -> Transcript? {
        await llmRuntime.foundationModelsCanonicalTranscript()
    }

    func foundationModelsContextProjection() async -> TranscriptContextProjection {
        await llmRuntime.foundationModelsContextProjection() ?? .empty
    }

    /// Captures all mutable MainActor values before awaiting disk I/O. The
    /// immutable snapshot therefore belongs to one conversation boundary even
    /// if navigation becomes reentrant while the repository is suspended.
    func persistActiveSession(id: String) async {
        let startedAt = Date()
        guard id == conversations.activeThreadID,
              let conversation = conversations.conversation(id: id) else {
            assertionFailure("Only the active conversation can use the visible timeline")
            return
        }
        guard !unreadableSessionIDs.contains(id) else {
            print("[TurboCode] Refused to overwrite unreadable session \(id)")
            return
        }
        let backend = modelRuntime.activeBackend
        let modelBackend = modelRuntime.persistedModelIdentifier
        let composerStatistics = statistics.activeStatistics
        let blocks = timeline.blocks
        let steering = await runtime.steeringSnapshot
        let transcript = backend == .codex
            ? nil
            : await llmRuntime.foundationModelsCanonicalTranscript()
        let contextProjection = backend == .codex
            ? TranscriptContextProjection.empty
            : await llmRuntime.foundationModelsContextProjection() ?? .empty
        // The awaits above can interleave with a thread switch. Provider state
        // read after it would belong to the next conversation, so skip this
        // checkpoint; the switch's own barrier checkpoint already saved it.
        guard conversations.activeThreadID == id else { return }
        let snapshot = ConversationSnapshot(
            conversation: conversation,
            modelBackend: modelBackend,
            blocks: blocks,
            // Codex persists its own rollout. Saving an unrelated Foundation
            // Models transcript would contaminate a later Codex restoration.
            transcript: transcript,
            contextProjection: contextProjection,
            steering: steering,
            statistics: composerStatistics
        )

        do {
            try await persistence.save(snapshot)
        } catch {
            print("[TurboCode] Failed to persist session: \(error.localizedDescription)")
        }
        await AgentDiagnosticsRecorder.shared.recordBoundary(
            RuntimeBoundaryMetric(
                boundary: .persistence,
                backend: backend.rawValue,
                durationMilliseconds: max(
                    0,
                    Int(Date().timeIntervalSince(startedAt) * 1_000)
                )
            )
        )
    }

    /// Active metadata is persisted with the complete matching timeline;
    /// inactive metadata preserves its previously stored content.
    func persistMetadata(id: String) async {
        if id == conversations.activeThreadID {
            await persistActiveSession(id: id)
            return
        }
        await persistMetadataOnly(id: id, failureLabel: "conversation metadata")
    }

    /// Title generation finishes after runtime ownership is released. Metadata
    /// only avoids resnapshotting a newer turn that may already be streaming.
    func persistGeneratedTitle(id: String) async {
        await persistMetadataOnly(id: id, failureLabel: "generated title")
    }

    /// Returns the session files that exist but could not be decoded. They
    /// stay out of the catalog, and on disk exactly as found, so no later
    /// save can replace them with an empty timeline.
    @discardableResult
    func restoreCatalog() async -> [UnreadableSessionFile] {
        guard let catalog = try? await persistence.loadCatalog() else { return [] }
        conversations.restoreCatalog(catalog.conversations)
        return catalog.unreadableSessions
    }

    func load(id: String) async -> ConversationLoadResult {
        do {
            guard let snapshot = try await persistence.load(id: id) else {
                return .missing
            }
            unreadableSessionIDs.remove(id)
            return .loaded(snapshot)
        } catch {
            unreadableSessionIDs.insert(id)
            print("[TurboCode] Could not load session \(id): \(error)")
            return .unreadable(reason: error.localizedDescription)
        }
    }

    /// Durable deletion precedes the observable mutation so a filesystem error
    /// cannot make a row disappear only to return on the next launch.
    func delete(id: String) async throws -> String? {
        try await persistence.delete(id: id)
        unreadableSessionIDs.remove(id)
        return conversations.removeThread(id: id)
    }

    func removeWorkspace(_ path: String) async -> WorkspacePersistenceRemoval {
        let removal = await persistence.removeWorkspace(
            path,
            visibleConversations: conversations.threads
        )
        _ = conversations.removeThreads(ids: removal.deletedConversationIDs)
        return removal
    }

    private func persistMetadataOnly(id: String, failureLabel: String) async {
        // The repository would also refuse (its load throws), but skipping
        // here keeps a known-unreadable session out of every write path.
        guard !unreadableSessionIDs.contains(id),
              let conversation = conversations.conversation(id: id) else { return }
        do {
            try await persistence.saveMetadata(
                conversation,
                defaultModelBackend: ModelBackend.foundationApple.rawValue
            )
        } catch {
            print("[TurboCode] Failed to persist \(failureLabel): \(error.localizedDescription)")
        }
    }
}
