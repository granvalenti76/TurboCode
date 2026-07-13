import AppIntents
import Foundation

// MARK: - Ask TurboCode Intent

/// An App Intent that sends a natural language request to TurboCode's AI model
/// and returns the assistant's response. Works with both standalone Llama/Apple
/// models and the orchestrator mode.
@available(macOS 13.0, iOS 16.0, watchOS 9.0, *)
struct AskTurboCodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask TurboCode"
    static let description: IntentDescription = """
        Sends a prompt to TurboCode's AI assistant and returns the response.
        You can ask questions, request code changes, or give instructions.
        """

    static let suggestedInvocationPhrase = "Ask TurboCode"

    /// The user's prompt or question.
    @Parameter(title: "Prompt",
               description: "What do you want to ask or instruct?")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask TurboCode \(\.$prompt)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AskIntentError.emptyPrompt
        }

        // Access the app's shared ChatStore through a static reference.
        // On macOS, intents run in-process, so ChatStore.shared is available
        // after the app has launched.
        guard let store = ChatStore.shared else {
            throw AskIntentError.appNotReady
        }

        // Send the message and wait for the stream to finish.
        await store.sendMessage(prompt)

        // Return the last assistant response.
        guard let lastBlock = store.blocks.last(where: { $0.kind == .assistant }),
              !lastBlock.text.isEmpty else {
            throw AskIntentError.emptyResponse
        }

        return .result(
            value: lastBlock.text,
            dialog: "\(lastBlock.text.prefix(200))"
        )
    }
}

// MARK: - Errors

enum AskIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case emptyPrompt
    case emptyResponse
    case appNotReady

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyPrompt:
            "Please provide a prompt."
        case .emptyResponse:
            "The model returned an empty response."
        case .appNotReady:
            "TurboCode is not running. Open the app first."
        }
    }
}
