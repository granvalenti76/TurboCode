import Foundation
import FoundationModels

/// Bridges MainActor conversation projections to UI-neutral persistence use
/// cases. The lifecycle coordinator consumes its immutable load/delete results;
/// this type owns snapshot plumbing and never mutates runtime presentation.
@MainActor
final class ConversationSessionCoordinator {
    private let conversations: ConversationStore
    private let timeline: ChatTimelineStore
    private let modelRuntime: ModelRuntimeStore
    private let llmRuntime: LLMRuntime
    private let persistence: ConversationPersistenceService

    init(
        conversations: ConversationStore,
        timeline: ChatTimelineStore,
        modelRuntime: ModelRuntimeStore,
        llmRuntime: LLMRuntime,
        persistence: ConversationPersistenceService
    ) {
        self.conversations = conversations
        self.timeline = timeline
        self.modelRuntime = modelRuntime
        self.llmRuntime = llmRuntime
        self.persistence = persistence
    }

    /// Value checkpoint used by context policies that must inspect the active
    /// Foundation Models history without retaining its owning session runtime.
    var foundationModelsTranscript: Transcript? {
        llmRuntime.foundationModelsTranscript
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
        let backend = modelRuntime.activeBackend
        let snapshot = ConversationSnapshot(
            conversation: conversation,
            modelBackend: modelRuntime.persistedModelIdentifier,
            blocks: timeline.blocks,
            // Codex persists its own rollout. Saving an unrelated Foundation
            // Models transcript would contaminate a later Codex restoration.
            transcript: backend == .codex
                ? nil
                : llmRuntime.foundationModelsTranscript
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

    func restoreCatalog() async {
        guard let catalog = try? await persistence.loadCatalog() else { return }
        conversations.restoreCatalog(catalog)
    }

    func load(id: String) async -> ConversationSnapshot? {
        try? await persistence.load(id: id)
    }

    /// Durable deletion precedes the observable mutation so a filesystem error
    /// cannot make a row disappear only to return on the next launch.
    func delete(id: String) async throws -> String? {
        try await persistence.delete(id: id)
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
        guard let conversation = conversations.conversation(id: id) else { return }
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
