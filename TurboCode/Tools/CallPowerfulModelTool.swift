import Foundation
import FoundationModels
import LlamaModelExecutor

// MARK: - Call Powerful Model Tool

/// Arguments for delegating a task to the powerful model.
@Generable
struct CallPowerfulModelArguments {
    /// The full task, question, or problem description to delegate.
    /// Include all necessary context so the powerful model can work independently.
    var task: String
}

/// A tool that lets the Apple on-device model delegate a task to a powerful
/// remote model via **LlamaModelExecutor**.
///
/// When the Apple orchestrator invokes this tool, it creates a temporary
/// `LanguageModelSession` backed by `LlamaModel`/`LlamaExecutor`, streams the
/// response, and returns the accumulated text as tool output. The Apple model
/// then synthesises the final answer for the user.
///
/// Because `LanguageModelSession` is `@MainActor`-isolated, the tool bridges
/// to the main actor inside its `call()` method via `MainActor.run`.
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

    /// The Llama configuration used to create the delegate model session.
    private let configuration: LlamaConfiguration

    /// Creates a tool that delegates to a Llama model server via `LlamaModelExecutor`.
    /// - Parameter configuration: The Llama connection and generation parameters.
    init(configuration: LlamaConfiguration) {
        self.configuration = configuration
    }

    func call(arguments: CallPowerfulModelArguments) async throws -> String {
        // LanguageModelSession is @MainActor-isolated, so we bridge to the
        // main actor via a Task to create the session and stream the response.
        let config = configuration
        let task = arguments.task

        return try await Task { @MainActor in
            let model = LlamaModel(configuration: config)
            let heavySession = LanguageModelSession(model: model)
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
