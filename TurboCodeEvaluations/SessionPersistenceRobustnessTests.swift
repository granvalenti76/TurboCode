import Foundation
import FoundationModels
import Testing
@testable import TurboCode

/// Session files are the only durable copy of a conversation. These tests pin
/// the failure behavior: a damaged or newer-format file must never hide other
/// sessions, never be rewritten implicitly, and an undecodable provider
/// transcript must degrade to timeline-only history instead of losing the
/// whole conversation.
@Suite("Session persistence robustness")
struct SessionPersistenceRobustnessTests {
    @Test("Catalog skips an unreadable session file and leaves it untouched")
    func catalogSkipsUnreadableFile() async throws {
        let directoryURL = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let repository = DiskConversationRepository(directoryURL: directoryURL)
        try await repository.save(snapshot(id: "first"))
        try await repository.save(snapshot(id: "second"))
        let brokenURL = directoryURL.appendingPathComponent("broken.json")
        let brokenBytes = Data("{ \"id\": \"broken\", \"title\": ".utf8)
        try brokenBytes.write(to: brokenURL)

        let catalog = try await repository.loadCatalog()

        #expect(Set(catalog.snapshots.map(\.conversation.id)) == ["first", "second"])
        #expect(catalog.unreadableSessions.map(\.fileName) == ["broken.json"])
        #expect(try await repository.list().count == 2)
        #expect(try Data(contentsOf: brokenURL) == brokenBytes)
    }

    @Test("Restoring the catalog reports unreadable sessions to the user")
    @MainActor
    func restoreReportsUnreadableSessions() async throws {
        let directoryURL = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let repository = DiskConversationRepository(directoryURL: directoryURL)
        try await repository.save(snapshot(id: "readable"))
        try Data("not json".utf8).write(
            to: directoryURL.appendingPathComponent("broken.json")
        )
        let store = ChatStore(conversationRepository: repository)

        await store.restoreSessions()

        #expect(store.threads.map(\.id) == ["readable"])
        let message = try #require(store.presentationViewModel.errorMessage)
        #expect(message.contains("1 saved conversation could not be read"))
    }

    @Test("An undecodable transcript falls back to timeline-only history")
    func undecodableTranscriptKeepsTimeline() async throws {
        let directoryURL = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let repository = DiskConversationRepository(directoryURL: directoryURL)
        let original = snapshot(
            id: "transcript",
            transcript: Transcript(entries: [
                .prompt(Transcript.Prompt(segments: [
                    .text(Transcript.TextSegment(content: "Hello"))
                ]))
            ]),
            projection: TranscriptContextProjection(excludedToolCallIDs: ["call"])
        )
        try await repository.save(original)
        try rewriteSession(id: "transcript", in: directoryURL) { object in
            object["transcript"] = ["entries": "not a transcript"]
            object["contextProjection"] = 42
            object["steering"] = "not a steering snapshot"
        }

        let loadedSnapshot = try await repository.load(id: "transcript")
        let loaded = try #require(loadedSnapshot)

        #expect(loaded.conversation.title == original.conversation.title)
        #expect(loaded.blocks == original.blocks)
        #expect(loaded.transcript == nil)
        #expect(loaded.contextProjection == .empty)
        #expect(loaded.steering.requests.isEmpty)
        // Restore rebuilds provider history from the surviving timeline.
        #expect(!SessionRebuildHistory.fromVisibleBlocks(loaded.blocks).isEmpty)
    }

    @Test("Recovered fields are recorded and missing legacy keys are not")
    func recoveredFieldsDistinguishCorruptionFromLegacy() throws {
        let current = StoredSession(title: "Session", projectName: "TurboCode")
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
        )
        object.removeValue(forKey: "transcript")
        object.removeValue(forKey: "steering")
        object["statistics"] = "corrupt"

        let decoded = try JSONDecoder().decode(
            StoredSession.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.recoveredFields == ["statistics"])
        #expect(decoded.statistics == nil)
    }

    @Test("Undecodable timeline blocks keep the whole session unreadable")
    func undecodableBlocksRejectSession() async throws {
        let directoryURL = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let repository = DiskConversationRepository(directoryURL: directoryURL)
        try await repository.save(snapshot(id: "blocks"))
        try rewriteSession(id: "blocks", in: directoryURL) { object in
            object["blocks"] = [["id": "missing-required-fields"]]
        }

        await #expect(throws: (any Error).self) {
            _ = try await repository.load(id: "blocks")
        }
        let catalog = try await repository.loadCatalog()
        #expect(catalog.snapshots.isEmpty)
        #expect(catalog.unreadableSessions.map(\.fileName) == ["blocks.json"])
    }

    // MARK: - Helpers

    private func snapshot(
        id: String,
        transcript: Transcript? = nil,
        projection: TranscriptContextProjection = .empty
    ) -> ConversationSnapshot {
        ConversationSnapshot(
            conversation: Conversation(id: id, title: "Session \(id)"),
            modelBackend: ModelBackend.foundationApple.rawValue,
            blocks: [
                ChatBlock(kind: .user, text: "Question \(id)"),
                ChatBlock(kind: .assistant, text: "Answer \(id)")
            ],
            transcript: transcript,
            contextProjection: projection
        )
    }

    private func rewriteSession(
        id: String,
        in directoryURL: URL,
        _ mutate: (inout [String: Any]) -> Void
    ) throws {
        let url = directoryURL.appendingPathComponent("\(id).json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        mutate(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "SessionPersistenceRobustnessTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
