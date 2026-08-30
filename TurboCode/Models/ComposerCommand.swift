import Foundation

/// Commands handled by the composer before a prompt reaches a model.
///
/// Keeping this vocabulary separate from `ChatStore` lets new application
/// commands, such as plugin reload, evolve without enlarging the conversation
/// facade or the model-facing tool catalog.
nonisolated enum ComposerCommand: Equatable, Sendable {
    case documentation
    case compact
    case reload
    case task(String?)
}
