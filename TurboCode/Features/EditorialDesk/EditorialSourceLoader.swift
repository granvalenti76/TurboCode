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
