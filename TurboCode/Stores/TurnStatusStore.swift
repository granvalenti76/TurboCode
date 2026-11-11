import Foundation
import Observation

/// Answers "how is it going?" typed during a running turn without involving
/// the working model.
///
/// A message sent while a turn runs normally becomes steering. When it is
/// only a progress question, routing it here keeps it out of the steering
/// queue and out of the transcript: the working model is not interrupted and
/// never sees the question or the answer. Nothing in this store is persisted.
@MainActor
@Observable
final class TurnStatusStore {
    struct Card: Equatable {
        enum Phase: Equatable {
            case generating
            case done
            case failed
        }

        let question: String
        var answer: String
        var phase: Phase
        var askedAt: Date
    }

    private(set) var card: Card?

    private let assistant: any TurnStatusAssisting
    /// Returns nil when no side answer may be given: no turn is running, or
    /// the on-device model is itself the one doing the work.
    private let context: @MainActor () -> TurnStatusContext?
    private let classificationTimeout: Duration
    private var generation: Task<Void, Never>?

    init(
        assistant: any TurnStatusAssisting,
        classificationTimeout: Duration = .seconds(2),
        context: @escaping @MainActor () -> TurnStatusContext?
    ) {
        self.assistant = assistant
        self.classificationTimeout = classificationTimeout
        self.context = context
    }

    /// Returns true when `text` was a progress question and is being answered
    /// here. False means the caller must deliver it as steering; every
    /// uncertain outcome is false, because a question that reaches the
    /// working model costs nothing while a withheld instruction is lost.
    func intercept(_ text: String) async -> Bool {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard assistant.isAvailable,
              TurnStatusPrompts.isStatusCandidate(question),
              context() != nil,
              await classify(question) == .statusQuestion,
              // The turn may have ended while the classifier was running.
              context() != nil else { return false }
        answer(question)
        return true
    }

    /// Regenerates the answer from the turn's current state.
    func refresh() {
        guard let question = card?.question else { return }
        answer(question)
    }

    func dismiss() {
        generation?.cancel()
        generation = nil
        card = nil
    }

    /// Hands the question back so it can be sent to the working model, the
    /// recovery path when the classifier took an instruction for a question.
    func takeQuestion() -> String? {
        let question = card?.question
        dismiss()
        return question
    }

    /// The classifier may be slow on first use while the model loads. The
    /// composer must not appear stuck, so a late answer counts as steering.
    private func classify(_ text: String) async -> SteeringMessageKind {
        let assistant = self.assistant
        let timeout = classificationTimeout
        return await withTaskGroup(of: SteeringMessageKind?.self) { group in
            group.addTask { await assistant.classify(text) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .instruction
        }
    }

    private func answer(_ question: String) {
        generation?.cancel()
        guard let context = context() else {
            card = Card(question: question, answer: "", phase: .failed, askedAt: Date())
            return
        }
        card = Card(question: question, answer: "", phase: .generating, askedAt: Date())
        let prompt = TurnStatusPrompts.summary(question: question, context: context)
        let assistant = self.assistant
        generation = Task { [weak self] in
            do {
                try await assistant.summarize(prompt: prompt) { text in
                    guard !Task.isCancelled else { return }
                    self?.card?.answer = text
                }
                guard !Task.isCancelled, let self else { return }
                // Read before writing: assigning through `card?.phase` while
                // the right-hand side also reads `card` is an overlapping
                // access to the same observed property and traps at run time.
                let isEmpty = card?.answer.isEmpty ?? true
                card?.phase = isEmpty ? .failed : .done
            } catch {
                guard !Task.isCancelled else { return }
                self?.card?.phase = .failed
            }
        }
    }
}
