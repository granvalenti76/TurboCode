import Foundation
import FoundationModels
import FoundationModelsUtilities

// MARK: - Call Powerful Model Tool

/// Arguments for delegating a task to the powerful model.
@Generable
struct CallPowerfulModelArguments {
    /// The full task, question, or problem description to delegate.
    /// Include all necessary context so the powerful model can work independently.
    var task: String
}

/// A tool that lets the Apple on-device model delegate a task to a powerful
/// remote model via a `ChatCompletionsLanguageModel` (OpenAI-compatible API).
///
/// When the Apple orchestrator invokes this tool, it creates a temporary
/// `LanguageModelSession` backed by `ChatCompletionsLanguageModel`, streams the
/// response, and returns the accumulated text as tool output. The Apple model
/// then synthesises the final answer for the user.
///
/// Because `LanguageModelSession` is `@MainActor`-isolated, the tool bridges
/// to the main actor inside its `call()` method via a `Task`.
struct CallPowerfulModelTool: Tool {
    typealias Arguments = CallPowerfulModelArguments
    typealias Output = String

    var name: String { "call_powerful_model" }
    var description: String {
        """
        Delegate a complex or resource-intensive task to a more capable AI model.
        Use this tool when the user's request requires deep reasoning, large code
        generation, multi-step analysis, or detailed research — anything that
        benefits from a larger, more powerful model.

        Provide a **self-contained task description** with all the context the
        other model needs (relevant code snippets, error messages, requirements).
        Do **not** include conversation history or meta-instructions — just the
        concrete problem.

        After receiving the response, synthesise it into a clear final answer
        for the user, preserving important details, code blocks, and explanations.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    /// Configuration for the remote OpenAI-compatible model server.
    private let modelName: String
    private let baseURL: URL
    private let temperature: Double
    /// Tools registered with the delegate session (e.g. read_file, grep, file_system).
    private let delegateTools: [any Tool]
    /// System instructions for the delegate session (workspace context, rules, etc.).
    private let delegateInstructions: String
    private let onToolStart: (@Sendable (Transcript.ToolCall) async -> Void)?
    private let onToolEnd: (@Sendable (Transcript.ToolCall, Transcript.ToolOutput) async -> Void)?

    /// Creates a tool that delegates to a remote model via `ChatCompletionsLanguageModel`.
    /// - Parameters:
    ///   - modelName: The model identifier sent in API requests.
    ///   - baseURL: The server's base URL (e.g. `http://127.0.0.1:8080/v1`).
    ///   - temperature: Default sampling temperature.
    ///   - delegateTools: Tools to register with the delegate session.
    ///   - delegateInstructions: System instructions for the delegate session.
    init(
        modelName: String,
        baseURL: URL,
        temperature: Double,
        delegateTools: [any Tool],
        delegateInstructions: String,
        onToolStart: (@Sendable (Transcript.ToolCall) async -> Void)? = nil,
        onToolEnd: (@Sendable (Transcript.ToolCall, Transcript.ToolOutput) async -> Void)? = nil
    ) {
        self.modelName = modelName
        self.baseURL = baseURL
        self.temperature = temperature
        self.delegateTools = delegateTools
        self.delegateInstructions = delegateInstructions
        self.onToolStart = onToolStart
        self.onToolEnd = onToolEnd
    }

    func call(arguments: CallPowerfulModelArguments) async throws -> String {
        let task = arguments.task
        let tools = delegateTools
        let instructions = delegateInstructions
        let name = modelName
        let url = baseURL
        let toolStart = onToolStart
        let toolEnd = onToolEnd

        return try await Task { @MainActor in
            let model = ChatCompletionsLanguageModel(name: name, url: url)

            let heavySession = LanguageModelSession(
                profile: DelegateProfile(
                    instructions: instructions,
                    tools: tools,
                    model: model,
                    onToolStart: toolStart,
                    onToolEnd: toolEnd
                ),
                history: []
            )
            var result = ""

            for try await snapshot in heavySession.streamResponse(to: task) {
                if !snapshot.content.isEmpty {
                    result = snapshot.content
                }
            }

            return result.isEmpty
                ? "The powerful model returned an empty response."
                : result
        }.value
    }
}
