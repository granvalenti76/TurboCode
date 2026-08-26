import Foundation

/// Result of publishing one editorial draft. The URL is returned so the host
/// can show a receipt without making the editorial module own workspace state.
nonisolated struct EditorialPublication: Sendable, Equatable {
    let fileName: String
    let url: URL
}

nonisolated enum EditorialDraftPublisherError: LocalizedError, Sendable {
    case missingWorkspace
    case workspaceIsNotDirectory
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .missingWorkspace:
            "Choose a workspace before publishing the draft."
        case .workspaceIsNotDirectory:
            "The selected workspace is not a folder."
        case .emptyDocument:
            "Add some text to the draft before publishing it."
        }
    }
}

/// Owns the one-way filesystem side effect of Publish Draft. It is kept
/// separate from the view model so the entire editorial feature can be
/// removed without changing the chat or workspace stores.
nonisolated enum EditorialDraftPublisher {
    static func publish(
        document: String,
        title: String,
        workspaceRoot: String,
        metadata: EditorialDeskMetadata = .empty,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> EditorialPublication {
        let trimmedDocument = document.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDocument.isEmpty else {
            throw EditorialDraftPublisherError.emptyDocument
        }
        guard !workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EditorialDraftPublisherError.missingWorkspace
        }

        let workspaceURL = URL(fileURLWithPath: workspaceRoot).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw EditorialDraftPublisherError.workspaceIsNotDirectory
        }

        let baseName = safeBaseName(title)
            ?? "Untitled-Draft-\(temporaryStamp(now))"
        let fileName = uniqueFileName(baseName: baseName, in: workspaceURL, fileManager: fileManager)
        let targetURL = try WorkspacePathResolver.resolve(fileName, within: workspaceRoot)
        let serializedDocument = markdownDocument(trimmedDocument, metadata: metadata)
        try Data(serializedDocument.utf8).write(to: targetURL, options: .atomic)
        return EditorialPublication(fileName: fileName, url: targetURL)
    }

    /// Uses standard Markdown front matter so editors and scripts can inspect
    /// newsroom metadata without requiring a TurboCode-specific file format.
    private static func markdownDocument(
        _ document: String,
        metadata: EditorialDeskMetadata
    ) -> String {
        guard !metadata.isEmpty else { return document }

        var lines = ["---"]
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
        return lines.joined(separator: "\n") + "\n\n" + document
    }

    private static func frontMatterValue(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\"\(escaped)\""
    }

    private static func safeBaseName(_ title: String) -> String? {
        let normalized = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".- "))

        guard !normalized.isEmpty, normalized != ".", normalized != ".." else {
            return nil
        }
        return String(normalized.prefix(180))
    }

    private static func temporaryStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }

    private static func uniqueFileName(
        baseName: String,
        in workspaceURL: URL,
        fileManager: FileManager
    ) -> String {
        let first = "\(baseName).md"
        guard fileManager.fileExists(atPath: workspaceURL.appendingPathComponent(first).path) else {
            return first
        }

        var suffix = 2
        while true {
            let candidate = "\(baseName)-\(suffix).md"
            if !fileManager.fileExists(atPath: workspaceURL.appendingPathComponent(candidate).path) {
                return candidate
            }
            suffix += 1
        }
    }
}
