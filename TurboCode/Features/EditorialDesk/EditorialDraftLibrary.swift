import Foundation
import CryptoKit

/// Lightweight menu value for one authentic Editorial Desk document. Ordinary
/// Markdown and protocol sidecars never enter the draft picker.
nonisolated struct EditorialDraftDescriptor: Identifiable, Sendable, Equatable {
    let relativePath: String
    let fileName: String
    let modifiedAt: Date?
    let isEditorialDraft: Bool

    var id: String { relativePath }
}

/// Bounded projection used by workspace-file widgets. It deliberately omits
/// article content and sidecars so recognizing a draft never turns a directory
/// hover into a document load.
nonisolated struct EditorialDraftSummary: Sendable, Equatable {
    let draftID: UUID
    let relativePath: String
    let title: String
    let sectionName: String?
    let typeName: String?
}

/// Structured projection loaded from a protocol-valid Markdown article.
nonisolated struct EditorialDraftFile: Sendable, Equatable {
    let descriptor: EditorialDraftDescriptor
    let draftID: UUID
    let draft: EditorialDraft
    let metadata: EditorialDeskMetadata
    let reviewContext: EditorialReviewContext?
}

nonisolated enum EditorialDraftLibraryError: LocalizedError, Sendable {
    case invalidUTF8(String)
    case fileTooLarge(String)
    case invalidDraftProtocol(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8(let name):
            "\(name) could not be read as UTF-8 Markdown."
        case .fileTooLarge(let name):
            "\(name) exceeds the 1 MB Editorial Desk limit."
        case .invalidDraftProtocol(let name):
            "\(name) is not a valid Editorial Desk draft."
        }
    }
}

/// Encodes the stable draft fields in standard YAML front matter and leaves
/// the article body as ordinary Markdown. Title and deck are metadata because
/// the modal edits them independently from the body.
nonisolated enum EditorialMarkdownCodec {
    static let protocolVersion = 1
    static let maximumByteCount = 1_048_576

    static func encode(
        draft: EditorialDraftSnapshot,
        draftID: UUID,
        metadata: EditorialDeskMetadata,
        reviewRelativePath: String? = nil
    ) -> String {
        var lines = [
            "---",
            "editorial_draft: true",
            "protocol_version: \(protocolVersion)",
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
        if let reviewRelativePath {
            lines.append("editorial_review: \(frontMatterValue(reviewRelativePath))")
        }
        lines.append("---")
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return lines.joined(separator: "\n") + "\n\n" + body
    }

    static func decode(_ markdown: String) -> (
        draftID: UUID?,
        draft: EditorialDraft,
        metadata: EditorialDeskMetadata,
        protocolVersion: Int?,
        reviewRelativePath: String?
    ) {
        guard let frontMatter = splitFrontMatter(markdown) else {
            return (nil, EditorialDraft(body: markdown), .empty, nil, nil)
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
            ),
            values["protocol_version"].flatMap(Int.init),
            values["editorial_review"]
        )
    }

    static func authenticDraftID(in markdownPrefix: String) -> UUID? {
        guard let frontMatter = splitFrontMatter(markdownPrefix) else { return nil }
        let values = parse(frontMatter.header)
        guard values["editorial_draft"] == "true",
              values["protocol_version"].flatMap(Int.init) == protocolVersion,
              let rawID = values["editorial_draft_id"],
              let draftID = UUID(uuidString: rawID) else { return nil }
        return draftID
    }

    static func splitFrontMatter(_ markdown: String) -> (header: String, body: String)? {
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

    static func parse(_ header: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in header.split(separator: "\n") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            values[key] = decodedFrontMatterValue(raw)
        }
        return values
    }

    static func frontMatterValue(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\"\(escaped)\""
    }

    static func decodedFrontMatterValue(_ value: String) -> String {
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

/// Machine-readable payload embedded in the human-readable review Markdown.
/// The Base64 transport avoids inventing a partial YAML parser for nested model
/// findings while the surrounding document remains useful outside TurboCode.
private nonisolated struct EditorialReviewPayload: Codable, Sendable {
    let action: EditorialAction
    let performedAt: Date
    let baseDraft: EditorialDraftSnapshot
    let result: EditorialResult
}

private nonisolated enum EditorialContentAddress {
    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Canonical Markdown representation of one immutable source snapshot. File
/// sources retain their original path as provenance, while pasted/manual text
/// remains fully recoverable when the draft is reopened.
private nonisolated enum EditorialSourceSidecarCodec {
    static func encode(_ source: EditorialSource) -> String {
        let origin: (kind: String, value: String) = switch source.origin {
        case .importedFile(let path): ("file", path)
        case .pasted: ("pasted", "")
        case .notes: ("notes", "")
        case .transcript: ("transcript", "")
        }
        var lines = [
            "---",
            "editorial_desk_source: true",
            "protocol_version: \(EditorialMarkdownCodec.protocolVersion)",
            "name: \(EditorialMarkdownCodec.frontMatterValue(source.name))",
            "origin_kind: \(EditorialMarkdownCodec.frontMatterValue(origin.kind))",
            "origin_value: \(EditorialMarkdownCodec.frontMatterValue(origin.value))",
            "---",
            "",
            "# \(source.name)",
            ""
        ]
        if case .importedFile(let path) = source.origin {
            lines.append("Original: [\(path)](\(originalLink(for: path)))")
            lines.append("")
        }
        lines.append("<!-- editorial-desk-source-content -->")
        lines.append(source.content)
        return lines.joined(separator: "\n")
    }

    static func decode(_ markdown: String) -> EditorialSource? {
        guard let frontMatter = EditorialMarkdownCodec.splitFrontMatter(markdown) else { return nil }
        let values = EditorialMarkdownCodec.parse(frontMatter.header)
        guard values["editorial_desk_source"] == "true",
              values["protocol_version"].flatMap(Int.init) == EditorialMarkdownCodec.protocolVersion,
              let name = values["name"],
              let kind = values["origin_kind"] else { return nil }
        let origin: EditorialSourceOrigin = switch kind {
        case "file": .importedFile(path: values["origin_value"] ?? "")
        case "pasted": .pasted
        case "notes": .notes
        case "transcript": .transcript
        default: .notes
        }
        let content = sourceContent(from: frontMatter.body)
        return EditorialSource(name: name, origin: origin, content: content)
    }

    private static func sourceContent(from body: String) -> String {
        let marker = "<!-- editorial-desk-source-content -->\n"
        guard let range = body.range(of: marker) else { return "" }
        return String(body[range.upperBound...])
    }

    private static func originalLink(for path: String) -> String {
        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path).absoluteString
        }
        let relative = "../../\(path)"
        return relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative
    }
}

/// One immutable editorial review. Findings are rendered as ordinary Markdown
/// and the same structured result is embedded for lossless modal restoration.
private nonisolated enum EditorialReviewSidecarCodec {
    struct Decoded: Sendable {
        let payload: EditorialReviewPayload
        let sourceReferences: [String]
    }

    static func encode(
        context: EditorialReviewContext,
        draftID: UUID,
        currentDraft: EditorialDraftSnapshot,
        sourceReferences: [String],
        previousReview: String?
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = EditorialReviewPayload(
            action: context.action,
            performedAt: context.performedAt,
            baseDraft: context.baseDraft,
            result: context.result
        )
        let payloadData = try encoder.encode(payload)
        var lines = [
            "---",
            "editorial_desk_review: true",
            "protocol_version: \(EditorialMarkdownCodec.protocolVersion)",
            "draft_id: \(EditorialMarkdownCodec.frontMatterValue(draftID.uuidString))",
            "action: \(EditorialMarkdownCodec.frontMatterValue(context.action.rawValue))",
            "reviewed_at: \(EditorialMarkdownCodec.frontMatterValue(iso8601(context.performedAt)))",
            "draft_revision: \(context.baseDraft.revision)",
            "draft_sha256: \(EditorialMarkdownCodec.frontMatterValue(EditorialContentAddress.sha256(context.baseDraft.document)))",
            "stale: \(context.isStale(comparedTo: currentDraft))",
            "payload_base64: \(EditorialMarkdownCodec.frontMatterValue(payloadData.base64EncodedString()))"
        ]
        if let previousReview {
            lines.append("previous_review: \(EditorialMarkdownCodec.frontMatterValue(previousReview))")
        }
        for (index, reference) in sourceReferences.enumerated() {
            lines.append("source_ref_\(index): \(EditorialMarkdownCodec.frontMatterValue(reference))")
        }
        lines.append(contentsOf: [
            "---",
            "",
            "# Editorial review",
            "",
            "**Action:** \(context.action.rawValue)",
            "",
            "**Summary:** \(context.result.summary)",
            "",
            "## Sources",
            ""
        ])
        if sourceReferences.isEmpty {
            lines.append("No ground-truth sources were attached.")
        } else {
            for (source, reference) in zip(context.sources, sourceReferences) {
                let fileName = URL(fileURLWithPath: reference).lastPathComponent
                lines.append("- [\(source.name)](../../../sources/\(fileName))")
            }
        }
        lines.append(contentsOf: ["", "## Findings", ""])
        if context.result.findings.isEmpty {
            lines.append("No findings.")
        } else {
            for finding in context.result.findings {
                lines.append("### \(finding.severity.rawValue.capitalized) — \(finding.sourceName)")
                lines.append("")
                lines.append(finding.explanation)
                if !finding.documentExcerpt.isEmpty {
                    lines.append("")
                    lines.append("> Draft: \(finding.documentExcerpt)")
                }
                if !finding.sourceExcerpt.isEmpty {
                    lines.append("")
                    lines.append("> Source: \(finding.sourceExcerpt)")
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func decode(_ markdown: String) -> Decoded? {
        guard let frontMatter = EditorialMarkdownCodec.splitFrontMatter(markdown) else { return nil }
        let values = EditorialMarkdownCodec.parse(frontMatter.header)
        guard values["editorial_desk_review"] == "true",
              values["protocol_version"].flatMap(Int.init) == EditorialMarkdownCodec.protocolVersion,
              let payloadText = values["payload_base64"],
              let payloadData = Data(base64Encoded: payloadText),
              let payload = try? JSONDecoder().decode(EditorialReviewPayload.self, from: payloadData) else {
            return nil
        }
        let references = values.compactMap { key, value -> (Int, String)? in
            guard key.hasPrefix("source_ref_"),
                  let index = Int(key.dropFirst("source_ref_".count)) else { return nil }
            return (index, value)
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
        return Decoded(payload: payload, sourceReferences: references)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Writes and restores the hidden v1 protocol. Sidecars are immutable and
/// content-addressed; the article is written last so its pointer can never
/// reference a partially created review package.
nonisolated enum EditorialDeskSidecarStore {
    /// A source can already occupy the 1 MB import allowance; protocol and
    /// review framing need bounded headroom when that snapshot is restored.
    private static let maximumSidecarByteCount = 4_194_304

    static func writeReview(
        context: EditorialReviewContext?,
        draftID: UUID,
        currentDraft: EditorialDraftSnapshot,
        previousReview: String?,
        workspaceRoot: String,
        fileManager: FileManager
    ) throws -> String? {
        guard let context else { return previousReview }
        let stale = context.isStale(comparedTo: currentDraft)
        if let previousReview,
           review(
               at: previousReview,
               represents: context,
               stale: stale,
               workspaceRoot: workspaceRoot,
               fileManager: fileManager
           ) {
            return previousReview
        }
        let sourceReferences = try context.sources.map {
            try writeSource($0, workspaceRoot: workspaceRoot, fileManager: fileManager)
        }
        let document = try EditorialReviewSidecarCodec.encode(
            context: context,
            draftID: draftID,
            currentDraft: currentDraft,
            sourceReferences: sourceReferences,
            previousReview: previousReview
        )
        let digest = EditorialContentAddress.sha256(document)
        let relativePath = ".editorial-desk/drafts/\(draftID.uuidString.lowercased())/reviews/\(digest).md"
        try writeIfNeeded(
            document,
            relativePath: relativePath,
            workspaceRoot: workspaceRoot,
            fileManager: fileManager
        )
        return relativePath
    }

    static func loadReview(
        relativePath: String,
        workspaceRoot: String,
        fileManager: FileManager = .default
    ) -> EditorialReviewContext? {
        guard let url = try? WorkspacePathResolver.resolve(relativePath, within: workspaceRoot),
              let data = try? Data(contentsOf: url),
              data.count <= maximumSidecarByteCount,
              let markdown = String(data: data, encoding: .utf8),
              let decoded = EditorialReviewSidecarCodec.decode(markdown) else { return nil }
        let sources = decoded.sourceReferences.compactMap { reference -> EditorialSource? in
            guard let sourceURL = try? WorkspacePathResolver.resolve(reference, within: workspaceRoot),
                  fileManager.fileExists(atPath: sourceURL.path),
                  let sourceData = try? Data(contentsOf: sourceURL),
                  sourceData.count <= maximumSidecarByteCount,
                  let sourceMarkdown = String(data: sourceData, encoding: .utf8) else { return nil }
            return EditorialSourceSidecarCodec.decode(sourceMarkdown)
        }
        return EditorialReviewContext(
            action: decoded.payload.action,
            performedAt: decoded.payload.performedAt,
            baseDraft: decoded.payload.baseDraft,
            sources: sources,
            result: decoded.payload.result
        )
    }

    /// Re-publishing an unchanged package must not manufacture review history.
    /// Source UUIDs are UI-local, so semantic equality uses durable provenance.
    private static func review(
        at relativePath: String,
        represents context: EditorialReviewContext,
        stale: Bool,
        workspaceRoot: String,
        fileManager: FileManager
    ) -> Bool {
        guard let url = try? WorkspacePathResolver.resolve(relativePath, within: workspaceRoot),
              let data = try? Data(contentsOf: url),
              data.count <= maximumSidecarByteCount,
              let markdown = String(data: data, encoding: .utf8),
              let frontMatter = EditorialMarkdownCodec.splitFrontMatter(markdown),
              EditorialMarkdownCodec.parse(frontMatter.header)["stale"] == String(stale),
              let existing = loadReview(
                  relativePath: relativePath,
                  workspaceRoot: workspaceRoot,
                  fileManager: fileManager
              ),
              existing.action == context.action,
              existing.performedAt == context.performedAt,
              existing.baseDraft == context.baseDraft,
              existing.result == context.result,
              existing.sources.count == context.sources.count else { return false }
        return zip(existing.sources, context.sources).allSatisfy { existing, current in
            existing.name == current.name
                && existing.origin == current.origin
                && existing.content == current.content
        }
    }

    private static func writeSource(
        _ source: EditorialSource,
        workspaceRoot: String,
        fileManager: FileManager
    ) throws -> String {
        let document = EditorialSourceSidecarCodec.encode(source)
        let digest = EditorialContentAddress.sha256(document)
        let relativePath = ".editorial-desk/sources/\(digest).md"
        try writeIfNeeded(
            document,
            relativePath: relativePath,
            workspaceRoot: workspaceRoot,
            fileManager: fileManager
        )
        return relativePath
    }

    private static func writeIfNeeded(
        _ document: String,
        relativePath: String,
        workspaceRoot: String,
        fileManager: FileManager
    ) throws {
        let url = try WorkspacePathResolver.resolve(relativePath, within: workspaceRoot)
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(document.utf8).write(to: url, options: .atomic)
    }
}

/// Reads protocol-valid draft articles away from MainActor. Enumeration skips
/// hidden/package descendants, which both keeps the picker responsive and
/// guarantees `.editorial-desk` sidecars cannot masquerade as articles.
actor EditorialDraftLibraryService {
    /// Recognizes one article from the same bounded front-matter prefix used by
    /// library enumeration. Ordinary Markdown returns nil without reading its
    /// body or any hidden review package.
    func summary(
        relativePath: String,
        workspaceRoot: String
    ) throws -> EditorialDraftSummary? {
        guard relativePath.lowercased().hasSuffix(".md") else { return nil }
        let url = try WorkspacePathResolver.resolve(relativePath, within: workspaceRoot)
        guard let prefix = readPrefix(from: url),
              let draftID = EditorialMarkdownCodec.authenticDraftID(in: prefix) else {
            return nil
        }
        let decoded = EditorialMarkdownCodec.decode(prefix)
        return EditorialDraftSummary(
            draftID: draftID,
            relativePath: relativePath,
            title: decoded.draft.title,
            sectionName: decoded.metadata.section?.name,
            typeName: decoded.metadata.type?.name
        )
    }

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
            guard let prefix = readPrefix(from: canonicalURL),
                  EditorialMarkdownCodec.authenticDraftID(in: prefix) != nil else { continue }
            results.append(
                EditorialDraftDescriptor(
                    relativePath: relativePath,
                    fileName: canonicalURL.lastPathComponent,
                    modifiedAt: values?.contentModificationDate,
                    isEditorialDraft: true
                )
            )
            if results.count >= max(1, limit) { break }
        }
        return results.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
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
        guard decoded.protocolVersion == EditorialMarkdownCodec.protocolVersion,
              let draftID = decoded.draftID,
              EditorialMarkdownCodec.authenticDraftID(in: markdown) == draftID else {
            throw EditorialDraftLibraryError.invalidDraftProtocol(url.lastPathComponent)
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return EditorialDraftFile(
            descriptor: EditorialDraftDescriptor(
                relativePath: relativePath,
                fileName: url.lastPathComponent,
                modifiedAt: values?.contentModificationDate,
                isEditorialDraft: true
            ),
            draftID: draftID,
            draft: decoded.draft,
            metadata: decoded.metadata,
            reviewContext: decoded.reviewRelativePath.flatMap {
                EditorialDeskSidecarStore.loadReview(
                    relativePath: $0,
                    workspaceRoot: workspaceRoot
                )
            }
        )
    }

    private func readPrefix(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4_096) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
