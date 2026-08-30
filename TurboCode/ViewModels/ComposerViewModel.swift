import Foundation
import Observation

// MARK: - ComposerViewModel

/// Owns transient composer input independently of chat orchestration.
///
/// The view model deliberately contains no provider session or send behavior.
/// A future TurboCodeCore client can consume the submitted values while SwiftUI
/// edits this MainActor projection without invalidating the conversation facade.
@MainActor
@Observable
final class ComposerViewModel {
    var messageText: String = ""
    var mode: ConversationMode = .agent

    var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func reset() {
        messageText = ""
    }
}
