import AppIntents
import Foundation

// MARK: - List Files in Directory Intent

/// An App Intent that lists files and directories at a given path.
/// Can be invoked via Shortcuts, Siri, or the app's command palette.
@available(macOS 13.0, iOS 16.0, watchOS 9.0, *)
struct ListFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "List Files in Directory"
    static let description: IntentDescription = """
        Lists all files and directories inside a specified path.
        Returns an array of file names, or an error if the path doesn't exist.
        """

    /// Phrase the user can say to Siri to invoke this intent.
    static let suggestedInvocationPhrase = "List files in directory in TurboCode"

    /// The directory path to list.
    @Parameter(title: "Directory Path",
               description: "Absolute path of the directory to list")
    var path: String

    /// Maximum number of results to return.
    @Parameter(title: "Max Results", default: 50)
    var maxResults: Int

    static var parameterSummary: some ParameterSummary {
        Summary("List files in \(\.$path)") {
            \.$maxResults
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let resolvedPath = NSString(string: path).standardizingPath

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
            throw IntentError.pathNotFound(path: path)
        }

        guard isDirectory.boolValue else {
            throw IntentError.notADirectory(path: resolvedPath)
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: resolvedPath),
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        let items = contents.prefix(maxResults).map { url -> String in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let prefix = isDir ? "[DIR]" : "     "
            let sizeStr = isDir ? "      -" : String(format: "%8d", size)
            return "\(prefix) \(sizeStr)  \(url.lastPathComponent)"
        }

        let summary: String
        if contents.count > maxResults {
            summary = "\(contents.count) items in \(resolvedPath) (showing first \(maxResults))"
        } else {
            summary = "\(contents.count) items in \(resolvedPath)"
        }

        return .result(
            value: items,
            dialog: "\(summary)"
        )
    }
}

// MARK: - Errors

enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case pathNotFound(path: String)
    case notADirectory(path: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .pathNotFound(let path):
            "The path '\(path)' does not exist."
        case .notADirectory(let path):
            "'\(path)' is not a directory."
        }
    }
}
