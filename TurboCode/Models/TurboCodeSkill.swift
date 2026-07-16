import Foundation

// MARK: - Disk-backed skills

nonisolated enum SkillModelProfileID: String, CaseIterable, Identifiable, Sendable, Hashable {
    case onDevice = "on-device"
    case llama
    case pcc
    case deepseek

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice: "On-device"
        case .llama: "Llama"
        case .pcc: "Apple PCC"
        case .deepseek: "DeepSeek"
        }
    }
}

nonisolated struct SkillModelOverride: Hashable, Sendable {
    var inheritsDefaults: Bool
    var toolIDs: [String]

    init(inheritsDefaults: Bool = true, toolIDs: [String] = []) {
        self.inheritsDefaults = inheritsDefaults
        self.toolIDs = toolIDs
    }
}

struct TurboCodeSkillDefinition: Identifiable, Hashable, Sendable {
    let name: String
    let description: String
    let prompt: String
    let profileOverrides: [String: SkillModelOverride]
    let unmanagedFrontMatterLines: [String]
    let sourceURL: URL

    var id: String { name }

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count <= 512_000 else {
            throw TurboCodeSkillError.fileTooLarge
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw TurboCodeSkillError.invalidUTF8
        }
        try self.init(source: source, sourceURL: url)
    }

    init(source: String, sourceURL: URL) throws {
        let lines = source.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let closingIndex = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
              }) else {
            throw TurboCodeSkillError.missingFrontMatter
        }

        let frontMatter = Array(lines[1..<closingIndex])
        let metadata = Self.parseMetadata(frontMatter)
        guard let name = metadata["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw TurboCodeSkillError.missingField("name")
        }
        guard Self.isValidName(name) else {
            throw TurboCodeSkillError.invalidName(name)
        }
        guard let description = metadata["description"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else {
            throw TurboCodeSkillError.missingField("description")
        }

        let bodyStart = lines.index(after: closingIndex)
        let prompt = lines[bodyStart...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw TurboCodeSkillError.emptyBody
        }

        self.name = name
        self.description = description
        self.prompt = prompt
        profileOverrides = Self.parseProfileOverrides(frontMatter)
        unmanagedFrontMatterLines = Self.unmanagedLines(frontMatter)
        self.sourceURL = sourceURL
    }

    static func render(
        name: String,
        description: String,
        prompt: String,
        profileOverrides: [String: SkillModelOverride],
        unmanagedFrontMatterLines: [String] = []
    ) throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw TurboCodeSkillError.missingField("name") }
        guard isValidName(trimmedName) else { throw TurboCodeSkillError.invalidName(trimmedName) }

        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else { throw TurboCodeSkillError.missingField("description") }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw TurboCodeSkillError.emptyBody }

        var lines = [
            "---",
            "name: \(yamlQuoted(trimmedName))",
            "description: \(yamlQuoted(trimmedDescription))"
        ]
        if !unmanagedFrontMatterLines.isEmpty {
            lines.append(contentsOf: unmanagedFrontMatterLines)
        }
        if !profileOverrides.isEmpty {
            lines.append("profiles:")
            for profileID in orderedProfileIDs(profileOverrides.keys) {
                guard let override = profileOverrides[profileID] else { continue }
                lines.append("  \(profileID):")
                lines.append("    inherit-defaults: \(override.inheritsDefaults ? "true" : "false")")
                lines.append("    tools:")
                for toolID in override.toolIDs {
                    lines.append("      - \(yamlQuoted(toolID))")
                }
            }
        }
        lines.append("---")
        lines.append(trimmedPrompt)
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$", options: .regularExpression) != nil
    }

    private static func parseMetadata(_ lines: [String]) -> [String: String] {
        var metadata: [String: String] = [:]
        var blockKey: String?
        var blockStyle: Character?
        var blockLines: [String] = []

        func finishBlock() {
            guard let key = blockKey else { return }
            let separator = blockStyle == ">" ? " " : "\n"
            metadata[key] = blockLines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: separator)
            blockKey = nil
            blockStyle = nil
            blockLines = []
        }

        for line in lines {
            if blockKey != nil, line.first?.isWhitespace == true {
                blockLines.append(line)
                continue
            }
            finishBlock()

            guard indentation(of: line) == 0 else { continue }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }

            if rawValue == "|" || rawValue == ">" {
                blockKey = key
                blockStyle = rawValue.first
                continue
            }
            metadata[key] = unquoted(rawValue)
        }
        finishBlock()
        return metadata
    }

    private static func parseProfileOverrides(_ lines: [String]) -> [String: SkillModelOverride] {
        guard let profilesIndex = lines.firstIndex(where: {
            indentation(of: $0) == 0 && $0.trimmingCharacters(in: .whitespaces) == "profiles:"
        }) else { return [:] }

        var overrides: [String: SkillModelOverride] = [:]
        var currentProfileID: String?
        var readingTools = false

        for line in lines.dropFirst(profilesIndex + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = indentation(of: line)
            if indent == 0 { break }

            if indent == 2, trimmed.hasSuffix(":"), !trimmed.hasPrefix("-") {
                let profileID = String(trimmed.dropLast())
                guard isValidIdentifier(profileID) else {
                    currentProfileID = nil
                    readingTools = false
                    continue
                }
                currentProfileID = profileID
                overrides[profileID] = SkillModelOverride()
                readingTools = false
                continue
            }

            guard let currentProfileID else { continue }
            if indent == 4, trimmed.hasPrefix("inherit-defaults:") {
                let raw = trimmed.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                overrides[currentProfileID]?.inheritsDefaults = raw != "false"
                readingTools = false
            } else if indent == 4, trimmed == "tools:" {
                readingTools = true
            } else if indent >= 6, readingTools, trimmed.hasPrefix("- ") {
                let toolID = unquoted(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                if !toolID.isEmpty, overrides[currentProfileID]?.toolIDs.contains(toolID) == false {
                    overrides[currentProfileID]?.toolIDs.append(toolID)
                }
            }
        }
        return overrides
    }

    private static func unmanagedLines(_ lines: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        let managedKeys: Set<String> = ["name", "description", "profiles"]

        while index < lines.count {
            let line = lines[index]
            guard indentation(of: line) == 0,
                  let key = topLevelKey(in: line) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < lines.count, indentation(of: lines[end]) > 0 || lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
                end += 1
            }
            if !managedKeys.contains(key) {
                result.append(contentsOf: lines[index..<end])
            }
            index = end
        }
        while result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            result.removeLast()
        }
        return result
    }

    private nonisolated static func indentation(of line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func topLevelKey(in line: String) -> String? {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private static func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if value.hasPrefix("'") && value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil
    }

    private static func orderedProfileIDs(_ values: Dictionary<String, SkillModelOverride>.Keys) -> [String] {
        let canonical = SkillModelProfileID.allCases.map(\.rawValue)
        let remaining = values.filter { !canonical.contains($0) }.sorted()
        return canonical.filter { values.contains($0) } + remaining
    }
}

enum TurboCodeSkillError: LocalizedError {
    case fileTooLarge
    case invalidUTF8
    case missingFrontMatter
    case missingField(String)
    case invalidName(String)
    case emptyBody
    case duplicateName(String)
    case protectedSkill(String)
    case unsafeSkillPath

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "SKILL.md exceeds the 500 KB limit."
        case .invalidUTF8:
            return "SKILL.md is not valid UTF-8 text."
        case .missingFrontMatter:
            return "SKILL.md must start with YAML front matter delimited by ---."
        case .missingField(let field):
            return "SKILL.md is missing the required '\(field)' field."
        case .invalidName(let name):
            return "Skill name '\(name)' must use lowercase letters, numbers, and hyphens."
        case .emptyBody:
            return "SKILL.md has no instruction body."
        case .duplicateName(let name):
            return "A skill named '\(name)' already exists."
        case .protectedSkill(let name):
            return "The built-in skill '\(name)' cannot be renamed or deleted."
        case .unsafeSkillPath:
            return "The skill path is outside ~/.turbocode/SKILLS."
        }
    }
}
