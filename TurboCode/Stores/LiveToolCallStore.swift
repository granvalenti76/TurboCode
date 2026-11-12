import Foundation
import Observation

/// Observable holder of the tool calls the model is writing in the running
/// turn, read by the Transcript sheet.
///
/// The store has no provider or persistence dependency: the native runner
/// pushes stream events through an output port and the reducer does the rest.
@MainActor
@Observable
final class LiveToolCallStore {
    private(set) var calls: [LiveToolCall] = []
    /// True between the start and the end of a native model request.
    private(set) var isActive = false
    private(set) var repetition: LiveToolCallRepetition?

    private var projection = LiveToolCallProjection()

    func handle(_ event: NativeToolCallStreamEvent) {
        switch event {
        case .started:
            projection = LiveToolCallProjection()
            isActive = true
        case .updated(let updates):
            // A delivery already in flight may land after the turn ended; it
            // must not reopen a list the sheet has stopped showing.
            guard isActive else { return }
            projection.apply(updates)
        case .finished:
            projection.closeOpenCalls()
            isActive = false
        }
        calls = projection.calls
        repetition = projection.repetition
    }
}
