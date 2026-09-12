import Foundation

nonisolated enum WorkspaceFilePreviewKind: Sendable, Equatable {
    case markdown
    case plainText
    case sourceCode
}

/// Bounded, current-filesystem projection used only by the live side of a
/// workspace listing. The immutable listing receipt remains the source of file
/// names and metadata shown in history.
nonisolated struct WorkspaceFilePreview: Sendable, Equatable {
    let relativePath: String
    let fileName: String
    let content: String
    let kind: WorkspaceFilePreviewKind
    /// Current on-disk size, distinct from the bounded prefix rendered below.
    let sizeBytes: Int
    let previewedByteCount: Int
    let isTruncated: Bool
    let isEditorialDraft: Bool
    let editorialTitle: String?

    init(
        relativePath: String,
        fileName: String,
        content: String,
        kind: WorkspaceFilePreviewKind,
        sizeBytes: Int,
        previewedByteCount: Int,
        isTruncated: Bool,
        isEditorialDraft: Bool = false,
        editorialTitle: String? = nil
    ) {
        self.relativePath = relativePath
        self.fileName = fileName
        self.content = content
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.previewedByteCount = previewedByteCount
        self.isTruncated = isTruncated
        self.isEditorialDraft = isEditorialDraft
        self.editorialTitle = editorialTitle
    }
}

nonisolated enum WorkspaceFilePreviewError: LocalizedError, Sendable, Equatable {
    case unsupportedFormat(String)
    case unavailable(String)
    case notRegularFile(String)
    case invalidUTF8(String)
    case pathChanged(String)
    case inactiveWorkspace

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let name):
            "Preview is not available for \(name)."
        case .unavailable(let name):
            "\(name) is no longer available in the workspace."
        case .notRegularFile(let name):
            "\(name) is not a regular file."
        case .invalidUTF8(let name):
            "\(name) could not be read as UTF-8 text."
        case .pathChanged(let name):
            "\(name) changed location while its preview was loading."
        case .inactiveWorkspace:
            "This listing is not associated with the active workspace."
        }
    }
}

/// Performs preview I/O away from MainActor and reads only a small prefix.
/// Rechecking the unresolved target after opening avoids presenting a symlink
/// that was retargeted during the read boundary.
actor WorkspaceFilePreviewService {
    static let maximumByteCount = 32_768

    func load(
        relativePath: String,
        workspaceRoot: String,
        maximumByteCount: Int = WorkspaceFilePreviewService.maximumByteCount
    ) throws -> WorkspaceFilePreview {
        let fileName = URL(fileURLWithPath: relativePath).lastPathComponent
        let kind = try previewKind(
            for: URL(fileURLWithPath: relativePath).pathExtension,
            fileName: fileName
        )
        let target = try WorkspacePathResolver.resolveForAccess(
            relativePath,
            within: workspaceRoot
        )
        guard target.isInsideWorkspace else {
            throw FileSystemError.outsideWorkspace(
                path: relativePath,
                workspace: workspaceRoot
            )
        }

        let values: URLResourceValues
        do {
            values = try target.url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
        } catch {
            throw WorkspaceFilePreviewError.unavailable(fileName)
        }
        guard values.isRegularFile == true else {
            throw WorkspaceFilePreviewError.notRegularFile(fileName)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: target.url)
        } catch {
            throw WorkspaceFilePreviewError.unavailable(fileName)
        }
        defer { try? handle.close() }
        guard WorkspacePathResolver.isUnchanged(target) else {
            throw WorkspaceFilePreviewError.pathChanged(fileName)
        }

        let byteLimit = max(1, maximumByteCount)
        let data: Data
        do {
            data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        } catch {
            throw WorkspaceFilePreviewError.unavailable(fileName)
        }
        let isTruncated = data.count > byteLimit
            || values.fileSize.map { $0 > byteLimit } == true
        let decoded = try decodeUTF8Prefix(
            Data(data.prefix(byteLimit)),
            fileName: fileName,
            mayEndMidScalar: isTruncated
        )
        return WorkspaceFilePreview(
            relativePath: relativePath,
            fileName: fileName,
            content: decoded.content,
            kind: kind,
            sizeBytes: values.fileSize ?? data.count,
            previewedByteCount: decoded.byteCount,
            isTruncated: isTruncated
        )
    }

    /// A bounded prefix may stop inside the final UTF-8 scalar. Only that
    /// incomplete suffix is discarded; malformed bytes elsewhere still fail.
    private func decodeUTF8Prefix(
        _ data: Data,
        fileName: String,
        mayEndMidScalar: Bool
    ) throws -> (content: String, byteCount: Int) {
        let maximumTrim = mayEndMidScalar ? min(3, data.count) : 0
        for trimCount in 0...maximumTrim {
            let candidate = trimCount == 0
                ? data
                : Data(data.dropLast(trimCount))
            if let content = String(data: candidate, encoding: .utf8) {
                return (content, candidate.count)
            }
        }
        throw WorkspaceFilePreviewError.invalidUTF8(fileName)
    }

    private func previewKind(
        for fileExtension: String,
        fileName: String
    ) throws -> WorkspaceFilePreviewKind {
        switch fileExtension.lowercased() {
        case "md", "markdown":
            return .markdown
        case "txt", "log", "csv", "tsv":
            return .plainText
        case "swift", "json", "plist", "yaml", "yml", "xml", "html", "css", "js", "ts", "py", "rb", "sh":
            return .sourceCode
        default:
            throw WorkspaceFilePreviewError.unsupportedFormat(fileName)
        }
    }
}
