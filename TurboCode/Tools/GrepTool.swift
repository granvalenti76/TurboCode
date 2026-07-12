import Foundation
import FoundationModels

// MARK: - Grep / Search Tool

/// Arguments for searching text
@Generable
struct SearchArguments {
    /// Regular expression or text pattern to search
    var pattern: String
    /// File or directory path to search in
    var path: String
    /// Maximum number of results to return (optional)
    var maxResults: Int?
}

/// Searches for a text pattern in a file or directory.
/// Corresponds to Kun's `grep` tool.
struct GrepTool: Tool {
    typealias Arguments = SearchArguments
    typealias Output = String

    var name: String { "grep" }
    var description: String { "Search for a text pattern in a file or directory. Returns matching lines with line numbers." }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: SearchArguments) async throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: arguments.path, isDirectory: &isDirectory) else {
            return "Error: Path '\(arguments.path)' does not exist"
        }

        if isDirectory.boolValue {
            return try searchDirectory(arguments.path, pattern: arguments.pattern, maxResults: arguments.maxResults)
        } else {
            return try searchFile(arguments.path, pattern: arguments.pattern, maxResults: arguments.maxResults)
        }
    }

    // MARK: - Private

    private func searchFile(_ path: String, pattern: String, maxResults: Int?) throws -> String {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        var results: [String] = []

        for (index, line) in lines.enumerated() {
            guard maxResults.map({ results.count < $0 }) ?? true else { break }
            if line.range(of: pattern, options: .regularExpression) != nil {
                results.append("\(index + 1): \(line)")
            }
        }

        if results.isEmpty { return "No matches found in '\(path)'" }
        return "\(path): \(results.count) matches\n\n\(results.joined(separator: "\n"))"
    }

    private func searchDirectory(_ path: String, pattern: String, maxResults: Int?) throws -> String {
        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var allResults: [String] = []
        var totalMatches = 0
        let resultLimit = maxResults ?? 50

        while let fileURL = enumerator?.nextObject() as? URL {
            guard totalMatches < resultLimit else {
                allResults.append("... (truncated, too many results)")
                break
            }

            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }
            guard !fileURL.pathComponents.contains(".git") else { continue }

            do {
                let matches = try searchFile(fileURL.path, pattern: pattern, maxResults: resultLimit - totalMatches)
                if !matches.hasPrefix("No matches") {
                    allResults.append("--- \(fileURL.path) ---\n\(matches)")
                    let countLine = matches.components(separatedBy: .newlines).first ?? ""
                    let count = Int(countLine.components(separatedBy: " ").dropLast().last ?? "0") ?? 1
                    totalMatches += count
                }
            } catch { continue }
        }

        if allResults.isEmpty { return "No matches found in '\(path)'" }
        return "\(totalMatches) matches in \(path)\n\n\(allResults.joined(separator: "\n\n"))"
    }
}
