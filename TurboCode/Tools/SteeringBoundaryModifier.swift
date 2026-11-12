import Foundation
import FoundationModels
import FoundationModelsUtilities

/// Delivers queued steering between two rounds of a running tool loop.
///
/// Without this, a native session can receive steering only when the turn
/// ends, or by cancelling the turn. Appending a prompt to the session history
/// when a tool finishes puts the instruction in the very next model request,
/// so the model reads it with the tool result and the turn keeps going.
///
/// `onToolOutput` is the only hook between a tool's completion and the next
/// request, and it fires before the framework appends the output. The prompt
/// therefore sits inside the tool exchange in the session transcript;
/// `Transcript.deferringPromptsPastToolOutputs` puts it back after the output
/// on the wire and in canonical history. Do not add this modifier to a
/// profile whose model does not go through that reordering.
struct SteeringBoundaryModifier: LanguageModelSession.DynamicProfileModifier {
    @SessionProperty(\.history)
    private var history

    /// Claims the queued steering text, or returns nil when there is none.
    /// A non-nil result is committed: the caller has already recorded the
    /// delivery, so the text must reach the history.
    let claim: (@Sendable () async -> String?)?

    func body(content: Content) -> some LanguageModelSession.DynamicProfile {
        content.onToolOutput {
            guard let claim, let text = await claim() else { return }
            history.append(.prompt(Transcript.Prompt(segments: [
                .text(Transcript.TextSegment(content: text))
            ])))
        }
    }
}
