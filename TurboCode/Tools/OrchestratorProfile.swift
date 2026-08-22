import Foundation
import FoundationModels
import FoundationModelsUtilities

// MARK: - Orchestrator Profile

/// A DynamicProfile that wraps instructions, tools, model selection, and
/// delegation lifecycle callbacks for the orchestrator feature.
///
/// When `onDelegationStart` / `onDelegationEnd` are non-nil, the profile
/// registers `onToolCall` / `onToolOutput` callbacks that fire on the
/// orchestrator's `call_powerful_model` invocations — no manual transcript
/// scanning required.
nonisolated struct TurboCodeDynamicProfile: LanguageModelSession.DynamicProfile {
    let instructions: String
    let tools: [any Tool]
    let model: any LanguageModel
    let onToolStart: (@Sendable (Transcript.ToolCall) async -> Void)?
    let onToolEnd: (@Sendable (Transcript.ToolCall, Transcript.ToolOutput) async -> Void)?
    let onDelegationStart: (@Sendable () async -> Void)?
    let onDelegationEnd: (@Sendable () async -> Void)?
    let reasoningLevel: ContextOptions.ReasoningLevel?

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            tools
        }
        .model(model)
        .reasoningLevel(reasoningLevel)
        .onToolCall { toolCall in
            if let action = onToolStart {
                await action(toolCall)
            }
            if toolCall.toolName == "call_powerful_model",
               let action = onDelegationStart {
                await action()
            }
        }
        .onToolOutput { call, output in
            if let action = onToolEnd {
                await action(call, output)
            }
            if call.toolName == "call_powerful_model",
               let action = onDelegationEnd {
                await action()
            }
        }
        .droppingCompletedToolCalls()
    }
}
