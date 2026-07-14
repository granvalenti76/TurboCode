import Foundation
import FoundationModels
import FoundationModelsUtilities

// MARK: - Delegate Profile

/// DynamicProfile for the delegate Llama session with history management.
struct DelegateProfile: LanguageModelSession.DynamicProfile {
    let instructions: String
    let tools: [any Tool]
    let model: any LanguageModel
    let temperature: Double?
    let reasoningLevel: ContextOptions.ReasoningLevel?
    let onToolStart: (@Sendable (Transcript.ToolCall) async -> Void)?
    let onToolEnd: (@Sendable (Transcript.ToolCall, Transcript.ToolOutput) async -> Void)?

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            tools
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
        .droppingCompletedToolCalls()
        .rollingWindow(entries: 20)
    }
}
