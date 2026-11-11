//===----------------------------------------------------------------------===//
//
// TurboCode addition to the Foundation Models utilities package.
//
//===----------------------------------------------------------------------===//

public import FoundationModels

extension Transcript {

  /// Moves a prompt that sits between a tool-call entry and its outputs to
  /// just after the last of those outputs.
  ///
  /// A prompt can be appended to a session's history while a tool loop is
  /// running, to steer the model without interrupting it. The only hook that
  /// fires between a tool's completion and the next model request,
  /// `onToolOutput`, runs *before* the framework appends the output, so the
  /// prompt lands inside the exchange. Chat-completion servers reject or
  /// misread an assistant `tool_calls` message that is not immediately
  /// followed by all of its `tool` messages; this restores that order.
  ///
  /// Entries that are already well ordered are returned unchanged, so the
  /// transform is safe to apply to any transcript and more than once.
  public static func deferringPromptsPastToolOutputs(
    _ entries: some Collection<Transcript.Entry>
  ) -> [Transcript.Entry] {
    var result: [Transcript.Entry] = []
    result.reserveCapacity(entries.count)
    var awaitedOutputIDs: Set<String> = []
    var deferredPrompts: [Transcript.Entry] = []

    func flush() {
      result.append(contentsOf: deferredPrompts)
      deferredPrompts.removeAll(keepingCapacity: true)
    }

    for entry in entries {
      switch entry {
      case .toolCalls(let calls):
        flush()
        awaitedOutputIDs = Set(calls.map(\.id))
        result.append(entry)
      case .toolOutput(let output):
        result.append(entry)
        awaitedOutputIDs.remove(output.id)
        if awaitedOutputIDs.isEmpty { flush() }
      case .prompt where !awaitedOutputIDs.isEmpty:
        deferredPrompts.append(entry)
      default:
        // Any other entry ends the exchange, for example after a call that
        // was interrupted and never produced an output.
        awaitedOutputIDs.removeAll(keepingCapacity: true)
        flush()
        result.append(entry)
      }
    }
    flush()
    return result
  }
}
