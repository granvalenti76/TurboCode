import Foundation

/// Reads explicitly selected text material for the desk. The loader accepts
/// arbitrary user-selected files and records their provenance; it does not
/// impose a README/PRODUCT-style filename allowlist.
nonisolated enum EditorialSourceLoader {
    /// Keep prompt payloads bounded before reading a user-selected file into
    /// memory. The limit applies to UTF-8 bytes, not visible character count.
    static let maxByteCount = 1_048_576

    static func load(
        from url: URL,
        workspaceRoot: String
    ) throws -> EditorialSource {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = resourceValues.fileSize,
           fileSize > maxByteCount {
            throw EditorialSourceLoadError.fileTooLarge(
                url.lastPathComponent,
                maxByteCount: maxByteCount
            )
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maxByteCount else {
            throw EditorialSourceLoadError.fileTooLarge(
                url.lastPathComponent,
                maxByteCount: maxByteCount
            )
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw EditorialSourceLoadError.invalidUTF8(url.lastPathComponent)
        }

        return EditorialSource(
            name: url.deletingPathExtension().lastPathComponent,
            origin: .importedFile(path: displayPath(for: url, workspaceRoot: workspaceRoot)),
            content: content
        )
    }

    private static func displayPath(for url: URL, workspaceRoot: String) -> String {
        guard !workspaceRoot.isEmpty else { return url.path }

        let root = URL(fileURLWithPath: workspaceRoot).standardizedFileURL.path
        let file = url.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard file.hasPrefix(prefix) else { return url.path }
        return String(file.dropFirst(prefix.count))
    }
}

nonisolated enum EditorialSourceLoadError: LocalizedError, Sendable {
    case invalidUTF8(String)
    case fileTooLarge(String, maxByteCount: Int)
    case duplicate(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8(let fileName):
            "\(fileName) could not be read as UTF-8 text."
        case .fileTooLarge(let fileName, let maxByteCount):
            "\(fileName) exceeds the \(maxByteCount / 1_024) KB source limit."
        case .duplicate(let sourceName):
            "\(sourceName) is already present in the editorial sources."
        }
    }
}

/// Result of importing a batch. Successful sources remain available even when
/// one selected file fails, so the UI can report partial import without
/// mutating its state from inside the file service.
nonisolated struct EditorialSourceImportResult: Sendable, Equatable {
    let sources: [EditorialSource]
    let errors: [String]
}

/// Owns source-file reads away from the MainActor. The loader remains a pure
/// one-file implementation for focused tests; this actor defines the runtime
/// boundary used by the editor.
actor EditorialSourceService {
    func load(
        urls: [URL],
        workspaceRoot: String,
        excluding existingSources: [EditorialSource] = []
    ) -> EditorialSourceImportResult {
        var sources: [EditorialSource] = []
        var errors: [String] = []
        var seenKeys = Set(existingSources.map {
            normalizedProvenanceKey(for: $0, workspaceRoot: workspaceRoot)
        })

        for url in urls {
            let sourceKey = "file:\(url.standardizedFileURL.path)"
            guard !seenKeys.contains(sourceKey) else {
                errors.append(
                    EditorialSourceLoadError.duplicate(url.lastPathComponent).localizedDescription
                )
                continue
            }

            do {
                let source = try EditorialSourceLoader.load(
                    from: url,
                    workspaceRoot: workspaceRoot
                )
                sources.append(source)
                seenKeys.insert(sourceKey)
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return EditorialSourceImportResult(sources: sources, errors: errors)
    }

    private func normalizedProvenanceKey(
        for source: EditorialSource,
        workspaceRoot: String
    ) -> String {
        guard case .importedFile(let path) = source.origin else {
            return source.provenanceKey
        }
        let resolvedURL: URL
        if path.hasPrefix("/") || workspaceRoot.isEmpty {
            resolvedURL = URL(fileURLWithPath: path)
        } else {
            resolvedURL = URL(fileURLWithPath: workspaceRoot)
                .appendingPathComponent(path)
        }
        return "file:\(resolvedURL.standardizedFileURL.path)"
    }
}
