import Foundation
import Observation
import Testing
@testable import TurboCode

@MainActor
@Suite("Conversation store")
struct ConversationStoreTests {
    @Test("Catalog filters by archive, project, and search before sorting")
    func catalogFiltersAndSortsThreads() {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let store = ConversationStore()
        store.threads = [
            Conversation(
                id: "archived",
                title: "Archived TurboCode",
                updatedAt: newer,
                isArchived: true,
                workspace: "/Work/TurboCode"
            ),
            Conversation(
                id: "pinned",
                title: "Pinned TurboCode",
                updatedAt: older,
                isPinned: true,
                workspace: "/Work/TurboCode"
            ),
            Conversation(
                id: "recent",
                title: "Recent TurboCode",
                updatedAt: newer,
                workspace: "/Work/TurboCode"
            ),
            Conversation(
                id: "other",
                title: "Other project",
                updatedAt: newer,
                workspace: "/Work/Elsewhere"
            ),
            Conversation(
                id: "general",
                title: "General TurboCode",
                updatedAt: newer
            )
        ]
        store.search = "turbocode"

        #expect(
            store.sortedThreads(selectedProject: "TurboCode").map(\.id)
                == ["pinned", "recent"]
        )

        store.showsArchivedThreads = true
        #expect(
            store.sortedThreads(selectedProject: "TurboCode").map(\.id)
                == ["pinned", "archived", "recent"]
        )

        #expect(store.sortedThreads(selectedProject: nil).map(\.id) == ["general"])
    }

    @Test("Metadata mutations preserve identity and update the catalog")
    func metadataMutationsUpdateCatalog() {
        let store = ConversationStore()
        store.threads = [Conversation(id: "thread", title: "Original")]

        store.renameThread(id: "thread", title: "Renamed")
        store.pinThread(id: "thread", pinned: true)
        store.archiveThread(id: "thread")

        #expect(store.threads.first?.title == "Renamed")
        #expect(store.threads.first?.isPinned == true)
        #expect(store.threads.first?.isArchived == true)

        store.restoreThread(id: "thread")
        #expect(store.threads.first?.isArchived == false)
    }

    @Test("Metadata persistence preserves an inactive thread timeline")
    func metadataPersistencePreservesInactiveTimeline() async throws {
        let originalConversation = Conversation(
            id: "thread",
            title: "Original",
            workspace: "/Work/TurboCode"
        )
        let originalBlock = ChatBlock(kind: .assistant, text: "Keep this transcript")
        let repository = RecordingConversationStoreRepository(
            snapshots: [
                ConversationSnapshot(
                    conversation: originalConversation,
                    modelBackend: ModelBackend.foundationApple.rawValue,
                    blocks: [originalBlock],
                    transcript: nil
                )
            ]
        )
        let store = ConversationStore()
        store.threads = [
            Conversation(
                id: "thread",
                title: "Renamed",
                isPinned: true,
                isArchived: true,
                workspace: "/Work/TurboCode",
                mode: .plan
            )
        ]

        let conversation = try #require(store.conversation(id: "thread"))
        let persistence = ConversationPersistenceService(repository: repository)
        try await persistence.saveMetadata(
            conversation,
            defaultModelBackend: ModelBackend.foundationApple.rawValue
        )
        let saved = try #require(repository.snapshots["thread"])

        #expect(saved.conversation.title == "Renamed")
        #expect(saved.conversation.isPinned)
        #expect(saved.conversation.isArchived)
        #expect(saved.conversation.mode == .plan)
        #expect(saved.modelBackend == ModelBackend.foundationApple.rawValue)
        #expect(saved.blocks == [originalBlock])
    }

    @Test("Export encodes the persisted session schema and skips unsaved drafts")
    func exportEncodesPersistedSessionSchema() async throws {
        let conversation = Conversation(
            id: "exported",
            title: "Export / me",
            workspace: "/Work/TurboCode"
        )
        let repository = RecordingConversationStoreRepository(
            snapshots: [
                ConversationSnapshot(
                    conversation: conversation,
                    modelBackend: ModelBackend.foundationApple.rawValue,
                    blocks: [ChatBlock(kind: .assistant, text: "Saved")],
                    transcript: nil
                )
            ]
        )
        let persistence = ConversationPersistenceService(repository: repository)

        let exports = try await persistence.exportJSON(
            ids: [conversation.id, "unsaved-draft"]
        )
        let item = try #require(exports.first)
        let stored = try JSONDecoder().decode(StoredSession.self, from: item.data)

        #expect(exports.count == 1)
        #expect(stored.id == conversation.id)
        #expect(stored.blocks.first?.text == "Saved")
        #expect(item.suggestedFileName.contains("Export _ me"))
    }

    @Test("ChatStore conversation forwarding remains observable")
    func chatStoreForwardingRemainsObservable() async {
        let store = ChatStore(conversationRepository: ConversationStoreRepository())

        await confirmation("Nested catalog mutation is observed") { observed in
            withObservationTracking {
                _ = store.threads
            } onChange: {
                observed()
            }
            await store.createThread(title: "Observed")
        }

        #expect(store.threads.map(\.title) == ["Observed"])
        #expect(store.activeThreadId == store.threads.first?.id)
    }

    @Test("Creating a chat replaces conversation-local presentation atomically")
    func creatingChatReplacesConversationPresentation() async {
        let store = ChatStore(conversationRepository: ConversationStoreRepository())
        store.timelineStore.restore([
            ChatBlock(kind: .assistant, text: "Previous conversation")
        ])
        store.workbenchStore.rightPanelMode = .workspaceListing
        store.workbenchStore.inspectedWorkspaceListingID = "previous-receipt"

        await store.createThread(title: "Fresh conversation")

        #expect(store.blocks.isEmpty)
        #expect(store.threads.map(\.title) == ["Fresh conversation"])
        #expect(store.activeThreadId == store.threads.first?.id)
        #expect(store.workbenchStore.rightPanelMode == nil)
        #expect(store.workbenchStore.inspectedWorkspaceListingID == nil)
    }

    @Test("Disk repository round trips and deletes a complete session")
    func diskRepositoryRoundTripsAndDeletesSession() async throws {
        let directoryURL = temporarySessionDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let repository = DiskConversationRepository(directoryURL: directoryURL)
        let conversation = Conversation(
            id: "round-trip",
            title: "Persisted session",
            isPinned: true,
            workspace: "/Work/TurboCode",
            mode: .plan
        )
        let block = ChatBlock(kind: .assistant, text: "Persisted response")
        let steeringRequest = SteeringRequest(
            id: SteeringRequestID(rawValue: "steering-request"),
            sequence: 1,
            context: SteeringContext(
                conversationID: conversation.id,
                originTurnID: TurnID(rawValue: "origin-turn"),
                contextGeneration: 3,
                workspaceRoot: "/Work/TurboCode",
                providerSelection: RuntimeBackendSelection(
                    backend: .foundationApple,
                    modelName: "configured-model"
                )
            ),
            text: "Keep the parser change focused",
            state: .delivered,
            receipt: SteeringDeliveryReceipt(
                deliveryID: SteeringDeliveryID(rawValue: "delivery"),
                providerTurnID: "provider-turn"
            )
        )
        let snapshot = ConversationSnapshot(
            conversation: conversation,
            modelBackend: ModelBackend.foundationApple.rawValue,
            blocks: [block],
            transcript: nil,
            steering: SteeringQueueSnapshot(
                contextGeneration: 3,
                requests: [steeringRequest],
                activeDelivery: nil
            )
        )

        try await repository.save(snapshot)

        let loadedSnapshot = try await repository.load(id: conversation.id)
        let loaded = try #require(loadedSnapshot)
        #expect(loaded.conversation == conversation)
        #expect(loaded.modelBackend == ModelBackend.foundationApple.rawValue)
        #expect(loaded.blocks == [block])
        #expect(loaded.steering.requests == [steeringRequest])
        #expect(try await repository.list().map(\.conversation.id) == [conversation.id])

        try await repository.delete(id: conversation.id)
        #expect(try await repository.load(id: conversation.id) == nil)
    }

    @Test("Disk repository rejects session IDs containing path syntax")
    func diskRepositoryRejectsPathTraversal() async {
        let directoryURL = temporarySessionDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let repository = DiskConversationRepository(directoryURL: directoryURL)
        let invalidID = "../outside"
        let snapshot = ConversationSnapshot(
            conversation: Conversation(id: invalidID, title: "Invalid"),
            modelBackend: ModelBackend.foundationApple.rawValue,
            blocks: [],
            transcript: nil
        )

        do {
            try await repository.save(snapshot)
            Issue.record("Expected the repository to reject a path-like session ID")
        } catch let error as ConversationRepositoryError {
            #expect(error == .invalidSessionID(invalidID))
        } catch {
            Issue.record("Unexpected repository error: \(error)")
        }
    }

    @Test("Concurrent saves leave one complete decodable session")
    func concurrentDiskSavesRemainDecodable() async throws {
        let directoryURL = temporarySessionDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let repository = DiskConversationRepository(directoryURL: directoryURL)
        let titles = (0..<20).map { "Revision \($0)" }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for title in titles {
                group.addTask {
                    let snapshot = ConversationSnapshot(
                        conversation: Conversation(id: "shared", title: title),
                        modelBackend: ModelBackend.foundationApple.rawValue,
                        blocks: [ChatBlock(kind: .assistant, text: title)],
                        transcript: nil
                    )
                    try await repository.save(snapshot)
                }
            }
            try await group.waitForAll()
        }

        let loadedSnapshot = try await repository.load(id: "shared")
        let loaded = try #require(loadedSnapshot)
        #expect(titles.contains(loaded.conversation.title))
        #expect(loaded.blocks.first?.text == loaded.conversation.title)
        #expect(try await repository.list().count == 1)
    }

    @Test("Workspace cleanup keeps rows whose durable deletion fails")
    func partialWorkspaceCleanupKeepsFailedRowsVisible() async {
        let workspace = "/Work/TurboCode"
        let deleted = Conversation(id: "deleted", title: "Deleted", workspace: workspace)
        let retained = Conversation(id: "retained", title: "Retained", workspace: workspace)
        let repository = RecordingConversationStoreRepository(
            snapshots: [
                makeSnapshot(deleted),
                makeSnapshot(retained)
            ],
            failingDeletionIDs: [retained.id]
        )
        let persistence = ConversationPersistenceService(repository: repository)
        let store = ConversationStore()
        store.threads = [deleted, retained]
        store.activeThreadID = retained.id

        let removal = await persistence.removeWorkspace(
            workspace,
            visibleConversations: store.threads
        )
        let removedActiveThread = store.removeThreads(
            ids: removal.deletedConversationIDs
        )

        #expect(removal.deletedConversationIDs == [deleted.id])
        #expect(removal.deletionErrors.count == 1)
        #expect(!removedActiveThread)
        #expect(store.threads.map(\.id) == [retained.id])
        #expect(store.activeThreadID == retained.id)
        #expect(repository.snapshots[deleted.id] == nil)
        #expect(repository.snapshots[retained.id] != nil)
    }

    private func temporarySessionDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "turbocode-session-repository-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func makeSnapshot(_ conversation: Conversation) -> ConversationSnapshot {
        ConversationSnapshot(
            conversation: conversation,
            modelBackend: ModelBackend.foundationApple.rawValue,
            blocks: [],
            transcript: nil
        )
    }
}

/// A no-op boundary keeps catalog tests independent from the user's persisted
/// sessions while still exercising the production dependency shape.
private struct ConversationStoreRepository: ConversationRepository {
    func save(_ snapshot: ConversationSnapshot) throws {}
    func load(id: String) throws -> ConversationSnapshot? { nil }
    func list() throws -> [ConversationSnapshot] { [] }
    func delete(id: String) throws {}
}

/// A synchronous recording repository verifies catalog-only writes without
/// touching the user's on-disk session directory.
private final class RecordingConversationStoreRepository: ConversationRepository, @unchecked Sendable {
    var snapshots: [String: ConversationSnapshot]
    private let failingDeletionIDs: Set<String>

    init(
        snapshots: [ConversationSnapshot],
        failingDeletionIDs: Set<String> = []
    ) {
        self.snapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.conversation.id, $0) })
        self.failingDeletionIDs = failingDeletionIDs
    }

    func save(_ snapshot: ConversationSnapshot) throws {
        snapshots[snapshot.conversation.id] = snapshot
    }

    func load(id: String) throws -> ConversationSnapshot? {
        snapshots[id]
    }

    func list() throws -> [ConversationSnapshot] {
        Array(snapshots.values)
    }

    func delete(id: String) throws {
        if failingDeletionIDs.contains(id) {
            throw RecordingConversationStoreRepositoryError.deletionDenied
        }
        snapshots.removeValue(forKey: id)
    }
}

private enum RecordingConversationStoreRepositoryError: Error {
    case deletionDenied
}
