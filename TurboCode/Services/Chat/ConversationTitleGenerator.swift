import Foundation
import FoundationModels

/// Generates optional conversation metadata outside the observable model store.
/// Implementations must use a short-lived session and never borrow or mutate the
/// active conversation session owned by ``LLMRuntime``.
@MainActor
protocol ConversationTitleGenerating: AnyObject {
    func generateTitle(from prompt: String) async -> String?
}

/// Foundation Models implementation used after the owning chat turn releases.
@MainActor
final class FoundationModelsConversationTitleGenerator:
    ConversationTitleGenerating {
    func generateTitle(from prompt: String) async -> String? {
        let titlePrompt = """
        Generate a very short title (max 6 words) for a conversation that starts with this message.
        Respond with ONLY the title, no quotes, no punctuation.

        Message: \(prompt)
        """

        do {
            let session = LanguageModelSession(model: SystemLanguageModel.default)
            var generated = ""
            for try await snapshot in session.streamResponse(to: titlePrompt) {
                if !snapshot.content.isEmpty {
                    generated = snapshot.content
                }
            }
            return Self.normalizedTitle(generated)
        } catch {
            // Title generation is optional; the conversation keeps "New Chat".
            return nil
        }
    }

    /// Keeps title cleanup deterministic and independently testable from model
    /// availability. The limit matches the persisted-title contract.
    nonisolated static func normalizedTitle(_ generated: String) -> String? {
        let clean = generated
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
        guard !clean.isEmpty else { return nil }
        return String(clean.prefix(60))
    }
}
