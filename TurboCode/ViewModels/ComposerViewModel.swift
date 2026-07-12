import Foundation
import Observation

// MARK: - ComposerViewModel

/// Manages transient composer state (message draft).
/// Persisted preferences (approval mode, reasoning effort, etc.)
/// live in the View via @AppStorage.
@MainActor
@Observable
final class ComposerViewModel {
    var messageText: String = ""

    var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func reset() {
        messageText = ""
    }
}
