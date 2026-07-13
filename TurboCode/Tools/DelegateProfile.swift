import Foundation
import FoundationModels
import FoundationModelsUtilities

// MARK: - Delegate Profile

/// DynamicProfile for the delegate Llama session with history management.
struct DelegateProfile: LanguageModelSession.DynamicProfile {
    let instructions: String
    let tools: [any Tool]
    let model: ChatCompletionsLanguageModel

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            tools
        }
        .model(model)
        .droppingCompletedToolCalls()
        .rollingWindow(entries: 20)
    }
}
