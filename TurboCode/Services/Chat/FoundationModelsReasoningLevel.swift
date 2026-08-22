import FoundationModels

/// Converts the provider-neutral product setting at the Foundation Models
/// adapter boundary. Core and observable configuration must not depend on
/// transport-specific reasoning option types.
@MainActor
enum FoundationModelsReasoningLevel {
    static func resolve(
        _ effort: ReasoningEffort?
    ) -> ContextOptions.ReasoningLevel? {
        switch effort {
        case .low: .light
        case .medium: .moderate
        case .high: .deep
        case nil: nil
        }
    }
}
