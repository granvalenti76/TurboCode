import FoundationModels

/// Converts the provider-neutral product setting at the Foundation Models
/// adapter boundary. Core and observable configuration must not depend on
/// transport-specific reasoning option types.
nonisolated enum FoundationModelsReasoningLevel {
    static func resolve(
        _ effort: ReasoningEffort?
    ) -> ContextOptions.ReasoningLevel? {
        switch effort {
        case .low: .light
        case .medium: .moderate
        // Foundation Models has no level above `.deep`; X-High adds prompt
        // guidance for local and on-device models while retaining the deepest
        // native level where one is available.
        case .high, .xhigh: .deep
        case nil: nil
        }
    }
}
