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
    var messageText: String = "" {
        didSet { editGeneration &+= 1 }
    }
    var mode: ConversationMode = .agent

    /// Lets asynchronous queue admission clear only the draft it observed;
    /// text entered while admission is suspended must never be discarded.
    private(set) var editGeneration: UInt64 = 0

    var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func reset() {
        messageText = ""
    }
}
