import Foundation
import Testing
@testable import TurboCode

@Suite("System prompt library and profile assignments")
struct SystemPromptLibraryTests {
    private static func temporaryLibrary() -> SystemPromptLibrary {
        SystemPromptLibrary(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemPromptLibraryTests-\(UUID().uuidString)", isDirectory: true))
    }

    private static func document(identity text: String) -> SystemPromptDocument {
        var document = SystemPromptDocument()
        document.setBlocks([SystemPromptBlock(title: "Me", text: text)], for: .identity)
        return document
    }

    @Test("Saved prompts are listed by name and assigned per profile")
    func savedPromptsResolvePerProfile() throws {
        let library = Self.temporaryLibrary()
        let ada = SystemPromptRecord(name: "Ada", basedOnDefault: true, document: Self.document(identity: "You are Ada."))
        let bob = SystemPromptRecord(name: "bob", basedOnDefault: false, document: Self.document(identity: "You are Bob."))
        try library.save(bob)
        try library.save(ada)
        try library.saveAssignments(SystemPromptAssignments(promptIDs: [.coding: ada.id, .delegate: bob.id]))

        #expect(library.records().map(\.name) == ["Ada", "bob"])
        let resolved = library.resolved()
        #expect(resolved.coding == ada.document)
        #expect(resolved.delegate == bob.document)
        #expect(resolved.studio == .turboCodeDefault)
        // Microtasks never take a user persona.
        #expect(resolved.document(forCodingRole: .microtask) == .turboCodeDefault)
        #expect(resolved.document(forCodingRole: .orchestrator) == ada.document)
    }

    @Test("Deleting an assigned prompt returns its profiles to the default")
    func deletingAssignedPromptFallsBack() throws {
        let library = Self.temporaryLibrary()
        let ada = SystemPromptRecord(name: "Ada", basedOnDefault: true, document: Self.document(identity: "You are Ada."))
        try library.save(ada)
        try library.saveAssignments(SystemPromptAssignments(promptIDs: [.coding: ada.id, .studio: ada.id]))

        try library.delete(ada.id)

        #expect(library.records().isEmpty)
        #expect(library.assignments().promptIDs.isEmpty)
        #expect(library.resolved() == .builtIn)
    }

    @Test("Unreadable files and dangling assignments never break resolution")
    func corruptFilesAreSkipped() throws {
        let library = Self.temporaryLibrary()
        let ada = SystemPromptRecord(name: "Ada", basedOnDefault: true, document: Self.document(identity: "You are Ada."))
        try library.save(ada)
        try Data("{not json".utf8).write(to: library.directoryURL.appendingPathComponent("\(UUID().uuidString).json"))
        // A copy saved under another name must not shadow the original.
        try FileManager.default.copyItem(
            at: library.directoryURL.appendingPathComponent("\(ada.id.uuidString).json"),
            to: library.directoryURL.appendingPathComponent("\(UUID().uuidString).json")
        )
        try library.saveAssignments(SystemPromptAssignments(promptIDs: [.coding: UUID()]))

        #expect(library.records().map(\.id) == [ada.id])
        #expect(library.resolved().coding == .turboCodeDefault)
    }

    @Test("The version grows only when the content changes")
    func versionTracksContentChanges() {
        let original = Self.document(identity: "One.")
        var record = SystemPromptRecord(name: "Ada", basedOnDefault: true, document: original)
        record.updateDocument(original)
        #expect(record.version == 1)
        record.name = "Ada 2"
        #expect(record.version == 1)
        record.updateDocument(Self.document(identity: "Two."))
        #expect(record.version == 2)
    }

    @Test("A session configuration routes each role to its profile's prompt")
    func configurationCarriesProfilePrompts() {
        let coding = Self.document(identity: "You are Ada.")
        let delegate = Self.document(identity: "You are a worker.")
        let prompts = ResolvedSystemPrompts(coding: coding, studio: .turboCodeDefault, delegate: delegate)

        func build(_ role: TurboCodeSystemPromptRole) -> String {
            TurboCodeSystemPromptBuilder.build(TurboCodeSystemPromptContext(
                role: role,
                backend: .llamaServer,
                workspaceRoot: "/tmp/project",
                agentTuning: .default,
                toolIDs: [],
                toolNames: [],
                availableSkills: [],
                workspaceInstructions: nil,
                promptDocument: prompts.document(forCodingRole: role)
            ))
        }
        #expect(build(.standalone).contains("You are Ada."))
        #expect(build(.delegate).contains("You are a worker."))
        #expect(build(.microtask).contains("You are TurboCode"))
    }
}
