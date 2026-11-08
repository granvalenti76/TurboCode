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

    /// Images waiting in the draft. Kept apart from `reset()` because steering
    /// and local commands clear the text but cannot consume images, which must
    /// stay in the draft for the next model turn.
    private(set) var imageAttachments: [ComposerImageAttachment] = []
    private(set) var imageNotice: String?
    @ObservationIgnored private var imageNoticeDismissal: Task<Void, Never>?

    var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func reset() {
        messageText = ""
    }

    func addImages(_ attachments: [ComposerImageAttachment]) {
        imageAttachments.append(contentsOf: attachments)
    }

    func removeImage(id: UUID) {
        imageAttachments.removeAll { $0.id == id }
    }

    /// Hands the draft's images to exactly one turn.
    func takeImages() -> [ComposerImageAttachment] {
        defer { imageAttachments = [] }
        return imageAttachments
    }

    /// Shows a brief notice that clears itself, keeping a refused drop out of
    /// the error banner because nothing has actually gone wrong.
    func showImageNotice(_ notice: String, for duration: Duration = .seconds(3)) {
        imageNoticeDismissal?.cancel()
        imageNotice = notice
        imageNoticeDismissal = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.imageNotice = nil
        }
    }
}
