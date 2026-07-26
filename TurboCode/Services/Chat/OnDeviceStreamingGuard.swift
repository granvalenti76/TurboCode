import Foundation

/// Stops a known Foundation Models degeneration before hundreds of empty
/// Markdown fences are rendered and persisted. It deliberately requires both
/// substantial output and extremely low information density.
nonisolated enum OnDeviceStreamingGuard {
    enum Failure: Error {
        case repetitiveOutput
    }

    static func isPathological(_ text: String) -> Bool {
        guard text.count >= 160 else { return false }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let fenceCount = lines.lazy.filter { $0.hasPrefix("```") }.count
        guard fenceCount >= 12 else { return false }

        let content = lines.filter { !$0.hasPrefix("```") }.joined()
        return content.count * 5 < text.count
    }
}
