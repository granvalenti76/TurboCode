import Foundation
import Testing
@testable import TurboCode

/// Coding | Cowork session management: sessions are created in the selected
/// domain, lists never mix domains, and a Cowork session's shared folder is
/// persisted and only mounted when it is safe and present.
@Suite("Cowork sessions")
@MainActor
struct CoworkSessionsTests {
    // MARK: Domain selection

    @Test("New sessions are created in the selected domain and Cowork has no Mac workspace")
    func newSessionsFollowActiveDomain() {
        let store = ConversationStore()
        store.activeDomain = .cowork

        let cowork = store.createThread(title: "Site", workspace: "/Work/TurboCode", mode: .agent)

        #expect(cowork.domain == .cowork)
        #expect(cowork.workspace == nil)

        store.activeDomain = .coding
        let coding = store.createThread(title: "Fix", workspace: "/Work/TurboCode", mode: .agent)
        #expect(coding.domain == .coding)
        #expect(coding.workspace == "/Work/TurboCode")
    }

    @Test("The first message in Cowork creates a Cowork session")
    func ensureActiveThreadUsesActiveDomain() {
        let store = ConversationStore()
        store.activeDomain = .cowork

        #expect(store.ensureActiveThread(workspace: "/Work/TurboCode", mode: .agent))

        #expect(store.threads.first?.domain == .cowork)
    }

    @Test("Chat lists never mix domains")
    func sortedThreadsFilterByDomain() {
        let store = ConversationStore()
        store.threads = [
            Conversation(id: "coding", title: "Coding"),
            Conversation(id: "cowork", title: "Cowork", domain: .cowork),
        ]

        store.activeDomain = .coding
        #expect(store.sortedThreads(selectedProject: nil).map(\.id) == ["coding"])
        store.activeDomain = .cowork
        #expect(store.sortedThreads(selectedProject: nil).map(\.id) == ["cowork"])
    }

    @Test("Opening a session moves the sidebar to that session's domain")
    func selectingSessionSyncsDomain() {
        let store = ConversationStore()
        store.threads = [Conversation(id: "cowork", title: "Cowork", domain: .cowork)]
        store.activeDomain = .coding

        store.activeThreadID = "cowork"

        #expect(store.activeDomain == .cowork)
    }

    @Test("Only Cowork sessions accept a shared folder")
    func sharedFolderOnlyForCowork() {
        let store = ConversationStore()
        store.threads = [
            Conversation(id: "coding", title: "Coding"),
            Conversation(id: "cowork", title: "Cowork", domain: .cowork),
        ]

        store.setCoworkFolder("/Users/someone/writing", for: "cowork")
        store.setCoworkFolder("/Users/someone/writing", for: "coding")

        #expect(store.threads.first { $0.id == "cowork" }?.coworkFolder == "/Users/someone/writing")
        #expect(store.threads.first { $0.id == "coding" }?.coworkFolder == nil)
    }

    // MARK: Persistence

    @Test("The shared folder persists and pre-0.62 sessions have none")
    func sharedFolderPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoworkSessionsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DiskConversationRepository(directoryURL: directory)
        let persistence = ConversationPersistenceService(repository: repository)
        var conversation = Conversation(id: "writing", title: "Writing", domain: .cowork)
        try await repository.save(ConversationSnapshot(
            conversation: conversation, modelBackend: ModelBackend.llamaServer.rawValue,
            blocks: [], transcript: nil
        ))

        conversation.coworkFolder = "/Users/someone/writing"
        try await persistence.saveMetadata(conversation, defaultModelBackend: ModelBackend.llamaServer.rawValue)

        let loaded = try #require(try await repository.load(id: "writing"))
        #expect(loaded.conversation.coworkFolder == "/Users/someone/writing")
        #expect(loaded.conversation.domain == .cowork)

        let legacy = StoredSession(title: "Old", projectName: "_general")
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        object.removeValue(forKey: "coworkFolder")
        object.removeValue(forKey: "domain")
        let decoded = try JSONDecoder().decode(
            StoredSession.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.coworkFolder == nil)
    }

    // MARK: Mounting

    @Test("A shared folder is mounted only when it exists, is a directory, and is allowed")
    func shareableFolderRules() throws {
        let home = try temporaryDirectory()
        let project = home.appendingPathComponent("writing", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(CoworkStore.shareableFolder(project.path, homeDirectory: home)?.path
            == project.resolvingSymlinksInPath().path)
        #expect(CoworkStore.shareableFolder(nil, homeDirectory: home) == nil)
        #expect(CoworkStore.shareableFolder(home.appendingPathComponent("gone").path, homeDirectory: home) == nil)
        #expect(CoworkStore.shareableFolder(file.path, homeDirectory: home) == nil)
        #expect(CoworkStore.shareableFolder(home.path, homeDirectory: home) == nil)
        #expect(CoworkStore.shareableFolder("/", homeDirectory: home) == nil)
    }

    @Test("No session context exists while Cowork is not installed")
    func noContextWhenUnavailable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "CoworkSessionsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "coworkEnabled")
        let store = CoworkStore(layout: CoworkSandboxLayout(root: root), defaults: defaults)

        #expect(!store.isAvailable)
        #expect(store.sessionContext(for: Conversation(title: "C", domain: .cowork)) == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoworkSessionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
