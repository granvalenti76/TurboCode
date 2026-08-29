import Foundation

/// Lightweight menu value for one Markdown document in the active workspace.
/// Editorial files sort first, while ordinary Markdown remains available so a
/// user can adopt an existing article without a separate import workflow.
nonisolated struct EditorialDraftDescriptor: Identifiable, Sendable, Equatable {
    let relativePath: String
    let fileName: String
    let modifiedAt: Date?
    let isEditorialDraft: Bool

    var id: String { relativePath }
}

/// Structured projection loaded from a Markdown file. A missing identity means
/// the file predates Editorial Desk and receives one on its first publication.
nonisolated struct EditorialDraftFile: Sendable, Equatable {
    let descriptor: EditorialDraftDescriptor
    let draftID: UUID?
    let draft: EditorialDraft
    let metadata: EditorialDeskMetadata
}

nonisolated enum EditorialDraftLibraryError: LocalizedError, Sendable {
    case invalidUTF8(String)
    case fileTooLarge(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8(let name):
            "\(name) could not be read as UTF-8 Markdown."
        case .fileTooLarge(let name):
            "\(name) exceeds the 1 MB Editorial Desk limit."
        }
    }
}

/// Encodes the stable draft fields in standard YAML front matter and leaves
/// the article body as ordinary Markdown. Title and deck are metadata because
/// the modal edits them independently from the body.
nonisolated enum EditorialMarkdownCodec {
    static let maximumByteCount = 1_048_576

    static func encode(
        draft: EditorialDraftSnapshot,
        draftID: UUID,
        metadata: EditorialDeskMetadata
    ) -> String {
        var lines = [
            "---",
            "editorial_draft: true",
            "editorial_draft_id: \(frontMatterValue(draftID.uuidString))",
            "title: \(frontMatterValue(draft.title))",
            "subtitle: \(frontMatterValue(draft.deck))"
        ]
        if let section = metadata.section {
            lines.append("editorial_section: \(frontMatterValue(section.name))")
            lines.append("editorial_section_symbol: \(frontMatterValue(section.systemImage))")
        }
        if let type = metadata.type {
            lines.append("editorial_type: \(frontMatterValue(type.name))")
            lines.append("editorial_type_symbol: \(frontMatterValue(type.systemImage))")
            lines.append("editorial_type_color: \(frontMatterValue(type.colorHex))")
        }
        if let date = metadata.dateString {
            lines.append("editorial_date: \(frontMatterValue(date))")
        }
        lines.append("---")
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return lines.joined(separator: "\n") + "\n\n" + body
    }

    static func decode(_ markdown: String) -> (
        draftID: UUID?,
        draft: EditorialDraft,
        metadata: EditorialDeskMetadata
    ) {
        guard let frontMatter = splitFrontMatter(markdown) else {
            return (nil, EditorialDraft(body: markdown), .empty)
        }
        let values = parse(frontMatter.header)
        let section = values["editorial_section"].map {
            EditorialDeskSection(
                name: $0,
                systemImage: values["editorial_section_symbol"] ?? "tag"
            )
        }
        let type = values["editorial_type"].map {
            EditorialDeskType(
                name: $0,
                systemImage: values["editorial_type_symbol"] ?? "doc.text",
                colorHex: values["editorial_type_color"] ?? "#0A84FF"
            )
        }
        return (
            values["editorial_draft_id"].flatMap(UUID.init(uuidString:)),
            EditorialDraft(
                title: values["title"] ?? "",
                deck: values["subtitle"] ?? "",
                body: frontMatter.body
            ),
            EditorialDeskMetadata(
                section: section,
                type: type,
                date: values["editorial_date"].flatMap(parseDate)
            )
        )
    }

    static func containsEditorialMarker(_ prefix: String) -> Bool {
        prefix.hasPrefix("---\n") && prefix.contains("\neditorial_draft: true\n")
    }

    private static func splitFrontMatter(_ markdown: String) -> (header: String, body: String)? {
        guard markdown.hasPrefix("---\n"),
              let range = markdown.range(of: "\n---", range: markdown.index(markdown.startIndex, offsetBy: 4)..<markdown.endIndex) else {
            return nil
        }
        let headerStart = markdown.index(markdown.startIndex, offsetBy: 4)
        let header = String(markdown[headerStart..<range.lowerBound])
        var bodyStart = range.upperBound
        if bodyStart < markdown.endIndex, markdown[bodyStart] == "\n" {
            bodyStart = markdown.index(after: bodyStart)
        }
        while bodyStart < markdown.endIndex, markdown[bodyStart] == "\n" {
            bodyStart = markdown.index(after: bodyStart)
        }
        return (header, String(markdown[bodyStart...]))
    }

    private static func parse(_ header: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: header.split(separator: "\n").compactMap { line in
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            return (key, decodedFrontMatterValue(raw))
        })
    }

    private static func frontMatterValue(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\"\(escaped)\""
    }

    private static func decodedFrontMatterValue(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else {
            return value
        }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

/// Reads Markdown library state away from MainActor. Enumeration is bounded
/// and skips hidden/package descendants so opening the desk remains responsive
/// in ordinary development workspaces.
actor EditorialDraftLibraryService {
    func list(workspaceRoot: String, limit: Int = 200) throws -> [EditorialDraftDescriptor] {
        let root = try WorkspacePathResolver.resolve(".", within: workspaceRoot)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [EditorialDraftDescriptor] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
            let relativePath = String(canonicalURL.path.dropFirst(root.path.count + 1))
            let values = try? canonicalURL.resourceValues(forKeys: Set(keys))
            let prefix = readPrefix(from: canonicalURL)
            results.append(
                EditorialDraftDescriptor(
                    relativePath: relativePath,
                    fileName: canonicalURL.lastPathComponent,
                    modifiedAt: values?.contentModificationDate,
                    isEditorialDraft: prefix.map(EditorialMarkdownCodec.containsEditorialMarker) ?? false
                )
            )
            if results.count >= max(1, limit) { break }
        }
        return results.sorted {
            if $0.isEditorialDraft != $1.isEditorialDraft {
                return $0.isEditorialDraft && !$1.isEditorialDraft
            }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    func load(relativePath: String, workspaceRoot: String) throws -> EditorialDraftFile {
        let url = try WorkspacePathResolver.resolve(relativePath, within: workspaceRoot)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= EditorialMarkdownCodec.maximumByteCount else {
            throw EditorialDraftLibraryError.fileTooLarge(url.lastPathComponent)
        }
        guard let markdown = String(data: data, encoding: .utf8) else {
            throw EditorialDraftLibraryError.invalidUTF8(url.lastPathComponent)
        }
        let decoded = EditorialMarkdownCodec.decode(markdown)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return EditorialDraftFile(
            descriptor: EditorialDraftDescriptor(
                relativePath: relativePath,
                fileName: url.lastPathComponent,
                modifiedAt: values?.contentModificationDate,
                isEditorialDraft: decoded.draftID != nil
            ),
            draftID: decoded.draftID,
            draft: decoded.draft,
            metadata: decoded.metadata
        )
    }

    private func readPrefix(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4_096) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
