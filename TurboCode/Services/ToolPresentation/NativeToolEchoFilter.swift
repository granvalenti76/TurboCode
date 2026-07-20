import Foundation

/// Removes only mechanical Markdown restatements of native structured results.
/// It deliberately preserves prose that discusses a file, because losing useful
/// analysis is worse than leaving a small amount of harmless repetition.
nonisolated enum NativeToolEchoFilter {
    static func filtering(
        _ text: String,
        workspaceListings: [WorkspaceListingBlock]
    ) -> String {
        let names = Set(
            workspaceListings
                .flatMap(\.entries)
                .map { $0.name.lowercased() }
        )
        guard !names.isEmpty, !text.isEmpty else { return text }

        let lines = text.components(separatedBy: .newlines)
        let echoLines = lines.map { isMechanicalEntryLine($0, entryNames: names) }
        guard echoLines.contains(true) else { return text }

        let retained = lines.enumerated().compactMap { index, line -> String? in
            if echoLines[index] { return nil }
            if isTableScaffolding(line) { return nil }
            if isListingBoilerplate(line) { return nil }
            return line
        }

        return collapsingBlankLines(in: retained)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isMechanicalEntryLine(
        _ line: String,
        entryNames: Set<String>
    ) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        guard entryNames.contains(where: { lowercased.contains($0) }) else { return false }

        let isListOrTableRow = trimmed.hasPrefix("-")
            || trimmed.hasPrefix("*")
            || trimmed.hasPrefix("•")
            || trimmed.hasPrefix("|")
            || trimmed.first?.isNumber == true
        let hasListingMetadata = [
            "byte", " kb", " mb", " gb", "modified", "(file", "(directory",
            "folder", "symbolic link", "symlink"
        ].contains(where: lowercased.contains)

        // Exact name-only rows are also mechanical, but descriptive bullets such
        // as "Package.swift defines the product" remain visible as analysis.
        let stripped = lowercased
            .trimmingCharacters(in: CharacterSet(charactersIn: "-*•|`0123456789. "))
        return (isListOrTableRow && hasListingMetadata) || entryNames.contains(stripped)
    }

    private static func isTableScaffolding(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("|") else { return false }
        let structural = CharacterSet(charactersIn: "|-: ")
        if trimmed.unicodeScalars.allSatisfy(structural.contains) { return true }
        let lowercased = trimmed.lowercased()
        return lowercased.contains("name")
            && (lowercased.contains("size") || lowercased.contains("modified") || lowercased.contains("kind"))
    }

    private static func isListingBoilerplate(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return false }
        return value.hasPrefix("here are the files")
            || value.hasPrefix("here’s the file")
            || value.hasPrefix("here is the file")
            || value.hasPrefix("the workspace contains")
            || value.hasPrefix("let me know if you want to inspect")
            || value.hasPrefix("let me know if you'd like to inspect")
    }

    private static func collapsingBlankLines(in lines: [String]) -> String {
        var result: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               result.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                continue
            }
            result.append(line)
        }
        return result.joined(separator: "\n")
    }
}
