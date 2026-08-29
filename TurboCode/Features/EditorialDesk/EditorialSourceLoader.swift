import Foundation

/// Reads explicitly selected text material for the desk. The loader accepts
/// arbitrary user-selected files and records their provenance; it does not
/// impose a README/PRODUCT-style filename allowlist.
nonisolated enum EditorialSourceLoader {
    static func load(
        from url: URL,
        workspaceRoot: String
    ) throws -> EditorialSource {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
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

    var errorDescription: String? {
        switch self {
        case .invalidUTF8(let fileName):
            "\(fileName) could not be read as UTF-8 text."
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
        workspaceRoot: String
    ) -> EditorialSourceImportResult {
        var sources: [EditorialSource] = []
        var errors: [String] = []

        for url in urls {
            do {
                sources.append(
                    try EditorialSourceLoader.load(
                        from: url,
                        workspaceRoot: workspaceRoot
                    )
                )
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return EditorialSourceImportResult(sources: sources, errors: errors)
    }
}
