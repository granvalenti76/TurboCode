import Foundation
import Testing
@testable import TurboCode

/// The session domain decides whether a conversation may use host tools or
/// only the Cowork VM, so its persistence must be backward compatible and must
/// never drift from `cowork` to `coding`.
@Suite("Session domain persistence")
struct SessionDomainPersistenceTests {
    @Test("Sessions saved before 0.62 decode as Coding")
    func legacySessionWithoutDomainDecodesAsCoding() throws {
        let current = StoredSession(title: "Legacy", projectName: "TurboCode")
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
        )
        object.removeValue(forKey: "domain")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(StoredSession.self, from: legacyData)

        #expect(decoded.domain == .coding)
        #expect(decoded.mode == .agent)
    }

    @Test("New sessions write the domain key explicitly")
    func newSessionsEncodeDomain() throws {
        let stored = StoredSession(title: "Cowork", projectName: "_general", domain: .cowork)
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any]
        )

        #expect(object["domain"] as? String == "cowork")
        #expect(object["schemaVersion"] as? Int == StoredSession.currentSchemaVersion)
    }

    @Test("Disk repository round trips a Cowork session")
    func diskRepositoryRoundTripsCoworkDomain() async throws {
        let directoryURL = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let repository = DiskConversationRepository(directoryURL: directoryURL)
        let conversation = Conversation(id: "cowork-session", title: "Build a site", domain: .cowork)

        try await repository.save(snapshot(for: conversation))

        let loaded = try #require(try await repository.load(id: conversation.id))
        #expect(loaded.conversation.domain == .cowork)
        #expect(try await repository.list().map(\.conversation.domain) == [.cowork])
    }

    @Test("Metadata edits cannot change a persisted domain")
    func metadataEditKeepsPersistedDomain() async throws {
        let directoryURL = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let repository = DiskConversationRepository(directoryURL: directoryURL)
        let persistence = ConversationPersistenceService(repository: repository)
        let original = Conversation(id: "cowork-rename", title: "Original", domain: .cowork)
        try await repository.save(snapshot(for: original))

        // Simulates a caller that rebuilt the conversation without a domain.
        let renamed = Conversation(
            id: original.id,
            title: "Renamed",
            createdAt: original.createdAt,
            isPinned: true
        )
        #expect(renamed.domain == .coding)
        try await persistence.saveMetadata(renamed, defaultModelBackend: ModelBackend.foundationApple.rawValue)

        let loaded = try #require(try await repository.load(id: original.id))
        #expect(loaded.conversation.domain == .cowork)
        #expect(loaded.conversation.title == "Renamed")
        #expect(loaded.conversation.isPinned)
    }

    @Test("Metadata for a new session keeps the caller's domain")
    func metadataForNewSessionUsesCallerDomain() async throws {
        let directoryURL = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let repository = DiskConversationRepository(directoryURL: directoryURL)
        let persistence = ConversationPersistenceService(repository: repository)
        let draft = Conversation(id: "cowork-draft", title: "Draft", domain: .cowork)

        try await persistence.saveMetadata(draft, defaultModelBackend: ModelBackend.foundationApple.rawValue)

        let loaded = try #require(try await repository.load(id: draft.id))
        #expect(loaded.conversation.domain == .cowork)
    }

    private func snapshot(for conversation: Conversation) -> ConversationSnapshot {
        ConversationSnapshot(
            conversation: conversation,
            modelBackend: ModelBackend.foundationApple.rawValue,
            blocks: [ChatBlock(kind: .assistant, text: "Done")],
            transcript: nil
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionDomainPersistenceTests-\(UUID().uuidString)", isDirectory: true)
    }
}
