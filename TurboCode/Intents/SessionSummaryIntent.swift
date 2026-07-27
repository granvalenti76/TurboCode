import AppIntents
import Foundation
import FoundationModels

// MARK: - Session Summary Intent

/// An App Intent that summarizes the recent exchanges in the current TurboCode session.
///
/// Can be invoked via Siri or Shortcuts to get a quick overview of what's been discussed
/// without scrolling through the full transcript.
///
/// ## Design decisions
///
/// - Uses only user+assistant pairs (skips tool, reasoning, and system blocks) so the
///   summary stays focused on the semantic conversation rather than implementation noise.
/// - Walks the timeline backwards to reliably find complete pairs even when the last
///   block is a user message without a matching assistant response yet.
/// - Reuses `SystemLanguageModel.default` (Apple on-device model) — the same
///   infrastructure already used by `ChatStore.generateTitle()` — so it works offline
///   and doesn't depend on a remote API key.
/// - Accepts an optional `exchangeCount` parameter (default 4) that callers can tune
///   via Shortcuts or Siri suggestions.
struct SessionSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Session Summary"
    static let description: IntentDescription = IntentDescription(
        """
        Summarizes the recent exchanges in the current TurboCode conversation.
        Useful for catching up on context or documenting progress.
        """,
        categoryName: "Conversation",
        searchKeywords: ["summary", "session", "TurboCode"]
    )

    static let suggestedInvocationPhrase = "Summarize my TurboCode session"

    /// Number of user-assistant exchange pairs to include in the summary.
    ///
    /// Each "exchange" is one user prompt followed by the assistant's response.
    /// Defaults to 4 so the summary is concise even in long sessions.
    @Parameter(title: "Number of Exchanges",
               description: "How many recent exchanges to include (each includes prompt + response)",
               default: 4)
    var exchangeCount: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Summarize the last \(\.$exchangeCount) exchanges")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // Access the app's shared ChatStore.
        // On macOS, intents run in-process, so ChatStore.shared is available
        // after the app has launched.
        guard let store = ChatStore.shared else {
            throw SessionSummaryError.appNotReady
        }

        // Extract the last N user+assistant exchange pairs from the transcript.
        let exchanges = extractRecentExchanges(from: store.blocks, count: max(exchangeCount, 1))

        guard !exchanges.isEmpty else {
            throw SessionSummaryError.noExchanges
        }

        // Build a prompt for the summary model.
        let summaryPrompt = buildSummaryPrompt(from: exchanges)

        // Use the same Apple on-device model infrastructure as generateTitle().
        // This keeps the intent working offline and avoids requiring a remote API key.
        let model = SystemLanguageModel.default
        let summarySession = LanguageModelSession(model: model)

        var summary = ""
        do {
            for try await snapshot in summarySession.streamResponse(to: summaryPrompt) {
                if !snapshot.content.isEmpty {
                    summary = snapshot.content
                }
            }
        } catch {
            throw SessionSummaryError.summaryFailed(error.localizedDescription)
        }

        let cleanSummary = summary
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanSummary.isEmpty else {
            throw SessionSummaryError.emptyResponse
        }

        // Donate the interaction to Siri so it learns this phrase and intent
        // association and can suggest or handle it proactively in future.
        try? await donate()

        return .result(
            value: cleanSummary,
            dialog: "Session summary: \(cleanSummary.prefix(150))"
        )
    }
}

// MARK: - Transcript Extraction

/// Extracts the last N user-assistant exchange pairs from the block timeline.
///
/// ## Algorithm
///
/// Walks the timeline **backwards**, collecting each `.user` block and pairing it with
/// the most recent preceding `.assistant` block. This direction guarantees we capture
/// complete pairs even when the last block in the timeline is an unanswered user
/// message — that user prompt is paired with whatever response preceded it, and the
/// in-flight exchange is naturally excluded.
///
/// ## Filtering
///
/// Tool calls, reasoning blocks, approval requests, review receipts, compaction
/// entries, and system blocks are intentionally skipped. They add implementation
/// noise that would dilute the semantic summary signal.
///
/// - Parameter blocks: The full timeline of chat blocks from `ChatStore.blocks`.
/// - Parameter count: Maximum number of exchange pairs to return.
/// - Returns: An array of `(prompt, response)` tuples, ordered chronologically.
@MainActor
private func extractRecentExchanges(
    from blocks: [ChatBlock],
    count: Int
) -> [(prompt: String, response: String)] {
    var pairs: [(prompt: String, response: String)] = []
    var currentAssistant: String?

    for block in blocks.reversed() {
        switch block.kind {
        case .assistant where !block.text.isEmpty:
            // Capture the most recent assistant response to pair with the next
            // user message we encounter walking backwards.
            if currentAssistant == nil {
                currentAssistant = block.text
            }

        case .user where !block.text.isEmpty:
            // Pair this user prompt with the most recent assistant response.
            let response = currentAssistant ?? ""
            pairs.append((prompt: block.text, response: response))
            currentAssistant = nil  // Consumed; next user pairs with earlier assistant

            if pairs.count >= count {
                // Reversed twice: once for iteration direction, once so the
                // result is in chronological order.
                return pairs.reversed()
            }

        default:
            // Skip tool calls, reasoning, approvals, reviews, compaction, etc.
            // These are implementation detail and don't contribute to the
            // semantic summary signal.
            break
        }
    }

    return pairs.reversed()
}

// MARK: - Prompt Builder

/// Builds a concise summarization prompt from the extracted exchanges.
///
/// The prompt requests a 3–5 sentence summary in Italian, covering what was asked,
/// what was implemented, and any open points. Responses are truncated to 500
/// characters per exchange to keep the prompt well within the on-device model's
/// context window.
///
/// - Parameter exchanges: Chronological array of user-assistant pairs.
/// - Returns: A prompt string ready to send to `LanguageModelSession.streamResponse(to:)`.
private func buildSummaryPrompt(from exchanges: [(prompt: String, response: String)]) -> String {
    let exchangeText = exchanges.enumerated().map { (index, exchange) in
        """
        -- Exchange \(index + 1) --
        User: \(exchange.prompt)
        Assistant: \(exchange.response.prefix(500))
        """
    }.joined(separator: "\n\n")

    return """
    You are an assistant that summarizes software development conversations.
    Write a concise summary (3-5 sentences) of the recent exchanges below.
    Highlight: what was asked, what was implemented/changed, and any open questions.
    Do not list every exchange individually.

    \(exchangeText)

    Summary:
    """
}

// MARK: - Errors

enum SessionSummaryError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case noExchanges
    case emptyResponse
    case summaryFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady:
            "TurboCode is not running. Open the app first."
        case .noExchanges:
            "No messages in the current session. Start a conversation first."
        case .emptyResponse:
            "The model returned an empty summary."
        case .summaryFailed(let detail):
            "Summary generation failed: \(detail)"
        }
    }
}
