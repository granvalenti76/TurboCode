import Foundation
import FoundationModels

// MARK: - Orchestrator Profile

/// A DynamicProfile that wraps instructions, tools, model selection, and
/// delegation lifecycle callbacks for the orchestrator feature.
///
/// When `onDelegationStart` / `onDelegationEnd` are non-nil, the profile
/// registers `onToolCall` / `onToolOutput` callbacks that fire on the
/// orchestrator's `call_powerful_model` invocations — no manual transcript
/// scanning required.
struct TurboCodeDynamicProfile: LanguageModelSession.DynamicProfile {
    let instructions: String
    let tools: [any Tool]
    let model: any LanguageModel
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
            if toolCall.toolName == "call_powerful_model",
               let action = onDelegationStart {
                await action()
            }
        }
        .onToolOutput { call, _ in
            if call.toolName == "call_powerful_model",
               let action = onDelegationEnd {
                await action()
            }
        }
    }
}
