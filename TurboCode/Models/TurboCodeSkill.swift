import Foundation

// MARK: - Disk-backed skills

struct TurboCodeSkillDefinition: Identifiable, Hashable, Sendable {
    let name: String
    let description: String
    let prompt: String
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

        let lines = source.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let closingIndex = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
              }) else {
            throw TurboCodeSkillError.missingFrontMatter
        }

        let metadata = Self.parseMetadata(Array(lines[1..<closingIndex]))
        guard let name = metadata["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw TurboCodeSkillError.missingField("name")
        }
        guard name.range(of: "^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$", options: .regularExpression) != nil else {
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
        self.sourceURL = url
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

            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }

            if value == "|" || value == ">" {
                blockKey = key
                blockStyle = value.first
                continue
            }
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            metadata[key] = value
        }
        finishBlock()
        return metadata
    }
}

enum TurboCodeSkillError: LocalizedError {
    case fileTooLarge
    case invalidUTF8
    case missingFrontMatter
    case missingField(String)
    case invalidName(String)
    case emptyBody

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
        }
    }
}
