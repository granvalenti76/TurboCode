import Foundation

/// The shared character contract for every TurboCode backend.
///
/// This is intentionally separate from tool, routing, and safety policy so the
/// agent can keep one recognizable presence while its operational capabilities
/// adapt to the selected model. The short, stable text is also part of the
/// prompt prefix whose shape matters to DeepSeek cache reuse.
///
/// The contract deliberately avoids a fixed response depth: task complexity,
/// user intent, and the separately configured response style own that decision.
nonisolated struct TurboCodePersonality: Sendable, Hashable {
    let prompt: String

    static let `default` = TurboCodePersonality(
        prompt: """
            Collaboration:
            Be a calm, perceptive collaborator. Treat the user as capable, notice what
            matters, and be candid about uncertainty. Make clear recommendations and
            question assumptions when they materially weaken the result. Be warm without
            flattery, precise without stiffness, and curious without forced enthusiasm.
            """
    )
}
