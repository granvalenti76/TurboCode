import Foundation

struct SkillEditorRecord: Identifiable, Hashable, Sendable {
    let sourceURL: URL
    let definition: TurboCodeSkillDefinition?
    let errorMessage: String?

    var id: String { sourceURL.path }
    var displayName: String {
        definition?.name ?? sourceURL.deletingLastPathComponent().lastPathComponent
    }
    var description: String {
        definition?.description ?? errorMessage ?? "Invalid SKILL.md"
    }
}

struct SkillDraft: Hashable, Sendable {
    let originalURL: URL?
    var name: String
    var description: String
    var prompt: String
    var profileOverrides: [String: SkillModelOverride]
    var unmanagedFrontMatterLines: [String]
    let isBuiltIn: Bool

    init(definition: TurboCodeSkillDefinition, builtInNames: Set<String>) {
        originalURL = definition.sourceURL
        name = definition.name
        description = definition.description
        prompt = definition.prompt
        profileOverrides = definition.profileOverrides
        unmanagedFrontMatterLines = definition.unmanagedFrontMatterLines
        isBuiltIn = builtInNames.contains(definition.name)
    }

    init(suggestedName: String) {
        originalURL = nil
        name = suggestedName
        description = "Describe when TurboCode should activate this skill"
        prompt = "# Skill\n\nDescribe the workflow, decision rules, and expected verification."
        profileOverrides = [:]
        unmanagedFrontMatterLines = []
        isBuiltIn = false
    }
}

struct SkillEditingService: Sendable {
    static let builtInNames: Set<String> = ["turbocode", "skill-creator"]

    let rootURL: URL

    static var live: SkillEditingService {
        SkillEditingService(rootURL: TurboCodeConfig.shared.skillsDirectoryURL)
    }

    func loadRecords() -> [SkillEditorRecord] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "SKILL.md" && isInsideRoot($0) }
            .map { url in
                do {
                    return SkillEditorRecord(
                        sourceURL: url,
                        definition: try TurboCodeSkillDefinition(contentsOf: url),
                        errorMessage: nil
                    )
                } catch {
                    return SkillEditorRecord(
                        sourceURL: url,
                        definition: nil,
                        errorMessage: error.localizedDescription
                    )
                }
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func save(_ draft: SkillDraft) throws -> TurboCodeSkillDefinition {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let source = try TurboCodeSkillDefinition.render(
            name: draft.name,
            description: draft.description,
            prompt: draft.prompt,
            profileOverrides: draft.profileOverrides,
            unmanagedFrontMatterLines: draft.unmanagedFrontMatterLines
        )
        let normalizedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationDirectory = rootURL.appendingPathComponent(normalizedName, isDirectory: true)
        let destinationURL = destinationDirectory.appendingPathComponent("SKILL.md")
        guard isInsideRoot(destinationURL) else { throw TurboCodeSkillError.unsafeSkillPath }

        let originalDirectory = draft.originalURL?.deletingLastPathComponent()
        let isRename = originalDirectory.map {
            $0.standardizedFileURL != destinationDirectory.standardizedFileURL
        } ?? false
        if draft.isBuiltIn, isRename {
            throw TurboCodeSkillError.protectedSkill(draft.name)
        }
        if isRename, FileManager.default.fileExists(atPath: destinationDirectory.path) {
            throw TurboCodeSkillError.duplicateName(normalizedName)
        }
        if draft.originalURL == nil, FileManager.default.fileExists(atPath: destinationDirectory.path) {
            throw TurboCodeSkillError.duplicateName(normalizedName)
        }

        var movedFrom: URL?
        do {
            if let originalDirectory, isRename {
                guard isInsideRoot(originalDirectory) else { throw TurboCodeSkillError.unsafeSkillPath }
                try FileManager.default.moveItem(at: originalDirectory, to: destinationDirectory)
                movedFrom = originalDirectory
            } else {
                try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            }
            try source.write(to: destinationURL, atomically: true, encoding: .utf8)
        } catch {
            if let movedFrom,
               FileManager.default.fileExists(atPath: destinationDirectory.path),
               !FileManager.default.fileExists(atPath: movedFrom.path) {
                try? FileManager.default.moveItem(at: destinationDirectory, to: movedFrom)
            }
            throw error
        }
        return try TurboCodeSkillDefinition(contentsOf: destinationURL)
    }

    func delete(_ draft: SkillDraft) throws {
        guard let sourceURL = draft.originalURL else { return }
        guard !draft.isBuiltIn else { throw TurboCodeSkillError.protectedSkill(draft.name) }
        let directory = sourceURL.deletingLastPathComponent()
        guard isInsideRoot(directory) else { throw TurboCodeSkillError.unsafeSkillPath }
        try FileManager.default.removeItem(at: directory)
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        return candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }
}
