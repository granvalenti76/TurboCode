import Foundation

/// A transient, user-visible description of one tool call in progress.
public struct ToolActivity: Identifiable, Sendable, Hashable {
    public let id: String
    /// Runtime function name used for lightweight tool-specific presentation.
    public let toolName: String?
    public let summary: String

    public init(id: String, toolName: String? = nil, summary: String) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
    }
}

/// Produces compact activity copy from ripgrep's actual invocation instead of
/// exposing its raw argument payload in the chat timeline.
nonisolated enum RipgrepActivitySummary {
    static func make(
        action: String?,
        pattern: String?,
        path: String?,
        filePattern: String?,
        filesOnly: Bool?
    ) -> String {
        let normalizedAction = concise(action, limit: 16)?.lowercased()
        let normalizedPath = concise(path, limit: 36)
        let scope = normalizedPath == nil || normalizedPath == "."
            ? nil
            : normalizedPath
        let glob = concise(filePattern, limit: 28)

        if normalizedAction == "files" {
            let operation = glob.map { "Finding \($0) files" }
                ?? "Discovering workspace files"
            return operation + scopeSuffix(scope)
        }

        guard let pattern = concise(pattern, limit: 42) else {
            return "Searching workspace" + scopeSuffix(scope)
        }
        let operation = filesOnly == true
            ? "Finding files containing “\(pattern)”"
            : "Searching for “\(pattern)”"
        let filter = glob.map { " · \($0)" } ?? ""
        return operation + filter + scopeSuffix(scope)
    }

    /// Whitespace and hard limits keep model-authored patterns readable in a
    /// single unobtrusive line, including expressions containing newlines.
    private static func concise(_ value: String?, limit: Int) -> String? {
        let normalized = value?
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let normalized, !normalized.isEmpty else { return nil }
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(limit - 1, 1))) + "…"
    }

    private static func scopeSuffix(_ scope: String?) -> String {
        scope.map { " in \($0)" } ?? ""
    }
}
