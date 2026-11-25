import Foundation
import Testing
@testable import TurboCode

@Suite("System prompt trials and ratings")
struct SystemPromptTrialTests {
    private static func temporaryLibrary() -> SystemPromptLibrary {
        SystemPromptLibrary(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemPromptTrialTests-\(UUID().uuidString)", isDirectory: true))
    }

    private static func document(_ identity: String) -> SystemPromptDocument {
        var document = SystemPromptDocument()
        document.setBlocks([SystemPromptBlock(title: "Me", text: identity)], for: .identity)
        return document
    }

    @Test("A trial replaces only its own kind of session's prompt")
    func trialReplacesOnlyItsDomain() {
        let profiles = ResolvedSystemPrompts(
            coding: Self.document("Coding"),
            studio: Self.document("Studio"),
            delegate: Self.document("Delegate")
        )
        let trial = Self.document("Trial")

        let coding = profiles.applyingTrial(trial, domain: .coding)
        #expect(coding.coding == trial)
        #expect(coding.studio == profiles.studio)
        #expect(coding.delegate == profiles.delegate)

        let studio = profiles.applyingTrial(trial, domain: .cowork)
        #expect(studio.studio == trial)
        #expect(studio.coding == profiles.coding)
        #expect(studio.delegate == profiles.delegate)
    }

    @Test("A trial finds its prompt, and a deleted prompt ends it")
    func trialResolvesItsRecord() throws {
        let library = Self.temporaryLibrary()
        let record = SystemPromptRecord(name: "Ada", basedOnDefault: true, document: Self.document("Ada"))
        try library.save(record)
        let trial = PromptTrial(promptID: record.id.uuidString, version: 1)

        #expect(library.record(for: trial)?.id == record.id)
        try library.delete(record.id)
        #expect(library.record(for: trial) == nil)
        #expect(library.record(for: PromptTrial(promptID: "not-a-uuid", version: 1)) == nil)
    }

    @Test("Ratings count only for the version they were given to")
    func ratingsAreScopedToVersion() throws {
        let library = Self.temporaryLibrary()
        var record = SystemPromptRecord(name: "Ada", basedOnDefault: true, document: Self.document("Ada"))
        try library.save(record)
        try library.addRating(SystemPromptRating(promptID: record.id, version: 1, stars: 5))
        try library.addRating(SystemPromptRating(promptID: record.id, version: 1, stars: 2))

        let first = try #require(library.ratingSummary(for: record.id, version: 1))
        #expect(first.count == 2)
        #expect(first.average == 3.5)

        record.updateDocument(Self.document("Ada, edited"))
        try library.save(record)
        #expect(library.ratingSummary(for: record.id, version: record.version) == nil)
        // The ratings file is not mistaken for a prompt.
        #expect(library.records().count == 1)
    }

    @Test("Stars are clamped and deleting a prompt drops its ratings")
    func ratingsAreClampedAndDeleted() throws {
        let library = Self.temporaryLibrary()
        let record = SystemPromptRecord(name: "Ada", basedOnDefault: true, document: Self.document("Ada"))
        try library.save(record)
        #expect(SystemPromptRating(promptID: record.id, version: 1, stars: 9).stars == 5)
        #expect(SystemPromptRating(promptID: record.id, version: 1, stars: 0).stars == 1)

        try library.addRating(SystemPromptRating(promptID: record.id, version: 1, stars: 4))
        try library.delete(record.id)
        #expect(library.ratings().isEmpty)
    }

    @Test("A session keeps its trial on disk, and older sessions have none")
    func storedSessionCarriesTheTrial() throws {
        var stored = StoredSession(title: "Try: Ada", projectName: "_general")
        stored.promptTrial = PromptTrial(promptID: UUID().uuidString, version: 3)
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(StoredSession.self, from: data)
        #expect(decoded.promptTrial == stored.promptTrial)

        let plain = try JSONEncoder().encode(StoredSession(title: "Chat", projectName: "_general"))
        #expect(!String(decoding: plain, as: UTF8.self).contains("promptTrial"))
        #expect(try JSONDecoder().decode(StoredSession.self, from: plain).promptTrial == nil)
    }
}
