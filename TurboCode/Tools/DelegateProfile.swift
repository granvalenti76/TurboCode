import Foundation
import FoundationModels
import FoundationModelsUtilities

// MARK: - Delegate Profile

/// DynamicProfile for the delegate Llama session with history management.
struct DelegateProfile: LanguageModelSession.DynamicProfile {
    let instructions: String
    let tools: [any Tool]
    let model: any LanguageModel
    let activations: SkillActivations
    let usesAgentWorkflowSkills: Bool
    let temperature: Double?
    let reasoningLevel: ContextOptions.ReasoningLevel?
    let onToolStart: (@Sendable (Transcript.ToolCall) async -> Void)?
    let onToolEnd: (@Sendable (Transcript.ToolCall, Transcript.ToolOutput) async -> Void)?

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            if usesAgentWorkflowSkills {
                // Delegated Llama/PCC work receives the same just-in-time loop
                // contract as a standalone session.
                AgentWorkflowSkills(activations: activations, tools: tools)
            } else {
                tools
            }
        }
        .model(model)
        .temperature(temperature)
        .reasoningLevel(reasoningLevel)
        .onToolCall { call in
            if let action = onToolStart {
                await action(call)
            }
        }
        .onToolOutput { call, output in
            if let action = onToolEnd {
                await action(call, output)
            }
        }
        .rollingWindow(entries: 20)
        .droppingCompletedToolCalls()
    }
}
