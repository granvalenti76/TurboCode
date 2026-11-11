import Foundation
import FoundationModels

/// What a message typed during a running turn is for.
nonisolated enum SteeringMessageKind: Sendable, Equatable {
    /// Only asks how the work is going. Answered on the side.
    case statusQuestion
    /// Anything the working model has to read.
    case instruction
}

/// The slice of the running turn handed to the on-device model.
nonisolated struct TurnStatusContext: Sendable, Equatable {
    var lastUserMessage: String
    var reasoning: String
    var assistantText: String
    var toolCalls: [LiveToolCall]
}

/// Pure routing and prompt construction for the turn-status side answer.
nonisolated enum TurnStatusPrompts {
    /// A progress question is short. Longer text goes straight to steering,
    /// which keeps real instructions away from the classifier entirely.
    static let candidateCharacterLimit = 140

    static func isStatusCandidate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.count <= candidateCharacterLimit
            && !trimmed.contains("\n")
    }

    /// The instructions are in English but name no keywords: users write in
    /// many languages, so the decision must rest on the model's reading of
    /// the message, never on matching phrases.
    static func classification(of text: String) -> String {
        """
        A user sent the message below to an AI agent that is busy working on a task.
        The message can be written in any language. Decide what the message is.
        STATUS: it only asks about progress, or what the agent is doing right now.
        INSTRUCTION: it asks the agent to do, change, stop, check or consider \
        anything, or you are not sure.
        Answer with exactly one word: STATUS or INSTRUCTION.

        Message: \(text)
        """
    }

    /// Unclear output counts as an instruction: delivering a question to the
    /// working model is harmless, withholding an instruction is not.
    static func kind(fromClassifierOutput output: String) -> SteeringMessageKind {
        let answer = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return answer.hasPrefix("STATUS") && !answer.contains("INSTRUCTION")
            ? .statusQuestion
            : .instruction
    }

    // Character budgets. Together with the fixed wording they keep the prompt
    // near 2,500 tokens, leaving most of the on-device model's 8K window for
    // the answer and for languages that tokenize less compactly than English.
    static let userMessageLimit = 1_500
    static let reasoningLimit = 2_500
    static let assistantTextLimit = 1_500
    static let toolCallLimit = 6
    static let toolArgumentsLimit = 240

    static func summary(question: String, context: TurnStatusContext) -> String {
        var sections = [
            """
            You are watching another AI agent work. Using only the notes below, \
            answer the user's question about its progress in at most four short \
            sentences. Write the answer in the language the question is written \
            in, whatever language the notes use. Say what it is doing \
            now, what it has already done, and what seems to remain. Do not invent \
            details; if the notes are not enough, say so.
            """,
            "User's question: \(question)"
        ]
        if !context.lastUserMessage.isEmpty {
            // The start of a task states the goal; its end is usually detail.
            sections.append(
                "Task the user gave the agent:\n"
                    + String(context.lastUserMessage.prefix(userMessageLimit))
            )
        }
        let calls = context.toolCalls.suffix(toolCallLimit)
        if !calls.isEmpty {
            let lines = calls.map { call in
                let arguments = call.arguments
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(toolArgumentsLimit)
                return "- \(call.name) (\(label(for: call.phase))): \(arguments)"
            }
            sections.append(
                "Agent's most recent tool calls, oldest first:\n"
                    + lines.joined(separator: "\n")
            )
        }
        // For text still being produced, the newest part is what matters.
        if !context.reasoning.isEmpty {
            sections.append(
                "Agent's latest reasoning:\n"
                    + String(context.reasoning.suffix(reasoningLimit))
            )
        }
        if !context.assistantText.isEmpty {
            sections.append(
                "Agent's latest written text:\n"
                    + String(context.assistantText.suffix(assistantTextLimit))
            )
        }
        return sections.joined(separator: "\n\n")
    }

    private static func label(for phase: LiveToolCall.Phase) -> String {
        switch phase {
        case .writing: "being written"
        case .written: "issued"
        case .interrupted: "interrupted"
        }
    }
}

/// Side model that answers progress questions about the running turn.
///
/// Implementations must use their own short-lived session and never borrow,
/// read or mutate the conversation session owned by ``LLMRuntime``: the
/// answer must not be visible to the working model.
@MainActor
protocol TurnStatusAssisting: AnyObject, Sendable {
    var isAvailable: Bool { get }
    /// Returns nil when no decision could be made.
    func classify(_ text: String) async -> SteeringMessageKind?
    /// Streams the cumulative answer through `onUpdate`.
    func summarize(
        prompt: String,
        onUpdate: @MainActor @Sendable (String) -> Void
    ) async throws
}

/// On-device implementation. Each call builds a fresh session, so nothing a
/// user asks about one turn leaks into the next answer.
@MainActor
final class FoundationModelsTurnStatusAssistant: TurnStatusAssisting {
    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    func classify(_ text: String) async -> SteeringMessageKind? {
        guard isAvailable else { return nil }
        do {
            let session = LanguageModelSession(model: SystemLanguageModel.default)
            let response = try await session.respond(
                to: TurnStatusPrompts.classification(of: text)
            )
            return TurnStatusPrompts.kind(fromClassifierOutput: response.content)
        } catch {
            return nil
        }
    }

    func summarize(
        prompt: String,
        onUpdate: @MainActor @Sendable (String) -> Void
    ) async throws {
        let session = LanguageModelSession(model: SystemLanguageModel.default)
        for try await snapshot in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            if !snapshot.content.isEmpty {
                onUpdate(snapshot.content)
            }
        }
    }
}
