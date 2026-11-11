import Foundation
import FoundationModelsUtilities

/// A tool call observed on the provider stream during the running turn.
///
/// Foundation Models adds a tool call to the transcript only once it is
/// complete, and the canonical transcript is synchronized at the end of the
/// turn. This value is the presentation-only view of what the model is
/// writing in the meantime; it is never persisted or sent back to a provider.
nonisolated struct LiveToolCall: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Argument fragments are still arriving.
        case writing
        /// The provider stream ended; the session runs the tool next.
        case written
        /// The turn ended before the provider finished writing the call.
        case interrupted
    }

    let id: String
    let callID: String
    /// One-based round of the tool loop inside the current turn.
    let round: Int
    var name: String
    var arguments: String
    /// Transport fragments received; providers emit roughly one per token.
    var fragmentCount: Int
    var phase: Phase
}

/// Consecutive identical tool calls at the end of the current turn.
nonisolated struct LiveToolCallRepetition: Equatable, Sendable {
    let toolName: String
    let count: Int
}

/// Pure reducer from relay updates to the live tool-call list.
///
/// Kept value-only so ordering, round numbering and loop detection are
/// testable without a model session or the main actor.
nonisolated struct LiveToolCallProjection: Equatable, Sendable {
    /// Identical consecutive calls needed before the UI warns. Two equal
    /// calls are common and legitimate (a retry, a re-read after an edit);
    /// three in a row is the usual signature of a small model looping.
    static let repetitionWarningThreshold = 3

    private(set) var calls: [LiveToolCall] = []
    private var rounds: [UUID: Int] = [:]

    mutating func apply(_ updates: [ReasoningStreamRelay.ToolCallUpdate]) {
        for update in updates {
            let round: Int
            if let known = rounds[update.streamID] {
                round = known
            } else {
                round = rounds.count + 1
                rounds[update.streamID] = round
            }
            let id = "\(update.streamID.uuidString)-\(update.index)"
            if let index = calls.lastIndex(where: { $0.id == id }) {
                calls[index].name = update.name
                calls[index].arguments += update.argumentsDelta
                calls[index].fragmentCount += update.fragmentCount
                if update.isComplete {
                    calls[index].phase = .written
                }
            } else {
                calls.append(
                    LiveToolCall(
                        id: id,
                        callID: update.id,
                        round: round,
                        name: update.name,
                        arguments: update.argumentsDelta,
                        fragmentCount: update.fragmentCount,
                        phase: update.isComplete ? .written : .writing
                    )
                )
            }
        }
    }

    /// Called when the turn ends. A failed or cancelled provider stream never
    /// reports completion, so its calls must not stay in the writing state.
    mutating func closeOpenCalls() {
        for index in calls.indices where calls[index].phase == .writing {
            calls[index].phase = .interrupted
        }
    }

    /// The trailing run of identical, fully written calls, when it is long
    /// enough to suggest a loop. A call still being written is ignored: its
    /// arguments are a prefix and would produce false matches.
    var repetition: LiveToolCallRepetition? {
        let written = calls.filter { $0.phase == .written }
        guard let last = written.last else { return nil }
        let signature = Self.signature(of: last)
        var count = 0
        for call in written.reversed() {
            guard Self.signature(of: call) == signature else { break }
            count += 1
        }
        guard count >= Self.repetitionWarningThreshold else { return nil }
        return LiveToolCallRepetition(toolName: last.name, count: count)
    }

    /// Key order and whitespace differ between otherwise identical calls of
    /// some models, so valid JSON is compared in canonical form.
    private static func signature(of call: LiveToolCall) -> String {
        let trimmed = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .fragmentsAllowed]
              ) else {
            return call.name + "\u{0}" + trimmed
        }
        return call.name + "\u{0}" + String(decoding: canonical, as: UTF8.self)
    }
}

/// Splits streamed tool-call arguments into readable fields.
///
/// While a call is being written its arguments are an incomplete JSON
/// object, which `JSONSerialization` rejects. This scanner reads the top
/// level leniently and returns whatever is available so far, with string
/// escapes decoded so commands and file contents show as real lines.
nonisolated enum ToolCallArgumentFormatter {
    struct Field: Equatable, Sendable {
        /// Empty when the text could not be attributed to a key.
        let key: String
        let value: String
        /// False for the field the model is still writing.
        let isComplete: Bool
    }

    static func fields(from raw: String) -> [Field] {
        let scalars = Array(raw.unicodeScalars)
        var index = 0
        skipWhitespace(scalars, &index)
        guard index < scalars.count else { return [] }
        guard scalars[index] == "{" else {
            // Not an object (or not JSON at all): show the text unmodified.
            return [Field(key: "", value: raw, isComplete: false)]
        }
        index += 1

        var fields: [Field] = []
        while true {
            skipWhitespace(scalars, &index, alsoSkipping: ",")
            guard index < scalars.count, scalars[index] != "}" else { break }
            guard scalars[index] == "\"" else {
                fields.append(
                    Field(key: "", value: string(scalars[index...]), isComplete: false)
                )
                break
            }
            let key = readString(scalars, &index)
            guard key.isClosed else {
                fields.append(Field(key: key.text, value: "", isComplete: false))
                break
            }
            skipWhitespace(scalars, &index)
            guard index < scalars.count, scalars[index] == ":" else {
                fields.append(Field(key: key.text, value: "", isComplete: false))
                break
            }
            index += 1
            skipWhitespace(scalars, &index)
            guard index < scalars.count else {
                fields.append(Field(key: key.text, value: "", isComplete: false))
                break
            }
            let value = scalars[index] == "\""
                ? readString(scalars, &index)
                : readRawValue(scalars, &index)
            fields.append(
                Field(key: key.text, value: value.text, isComplete: value.isClosed)
            )
            guard value.isClosed else { break }
        }
        return fields
    }

    private static func skipWhitespace(
        _ scalars: [Unicode.Scalar],
        _ index: inout Int,
        alsoSkipping extra: Unicode.Scalar? = nil
    ) {
        while index < scalars.count,
              scalars[index].properties.isWhitespace || scalars[index] == extra {
            index += 1
        }
    }

    /// Reads a JSON string starting at its opening quote and decodes its
    /// escapes. `isClosed` is false when the input ends inside the string.
    private static func readString(
        _ scalars: [Unicode.Scalar],
        _ index: inout Int
    ) -> (text: String, isClosed: Bool) {
        var output = String.UnicodeScalarView()
        index += 1
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\"" {
                index += 1
                return (String(output), true)
            }
            guard scalar == "\\" else {
                output.append(scalar)
                index += 1
                continue
            }
            // An escape split across two fragments is left for the next update.
            guard index + 1 < scalars.count else { break }
            let escaped = scalars[index + 1]
            switch escaped {
            case "n": output.append("\n")
            case "t": output.append("\t")
            case "r": output.append("\r")
            case "b": output.append("\u{8}")
            case "f": output.append("\u{C}")
            case "u":
                guard index + 5 < scalars.count else {
                    index = scalars.count
                    return (String(output), false)
                }
                let hex = string(scalars[(index + 2)...(index + 5)])
                // Surrogate halves are not scalars on their own; the
                // replacement character keeps the preview readable.
                output.append(
                    UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init) ?? "\u{FFFD}"
                )
                index += 4
            default: output.append(escaped)
            }
            index += 2
        }
        index = scalars.count
        return (String(output), false)
    }

    /// Reads a number, literal, array or nested object verbatim up to the
    /// separator that ends it at the top level, which is left unconsumed.
    private static func readRawValue(
        _ scalars: [Unicode.Scalar],
        _ index: inout Int
    ) -> (text: String, isClosed: Bool) {
        let start = index
        var depth = 0
        var isInsideString = false
        while index < scalars.count {
            let scalar = scalars[index]
            if isInsideString {
                if scalar == "\\" {
                    index += 1
                } else if scalar == "\"" {
                    isInsideString = false
                }
            } else if scalar == "\"" {
                isInsideString = true
            } else if scalar == "{" || scalar == "[" {
                depth += 1
            } else if scalar == "}" || scalar == "]" {
                if depth == 0 { break }
                depth -= 1
            } else if scalar == ",", depth == 0 {
                break
            }
            index += 1
        }
        let end = min(index, scalars.count)
        let text = string(scalars[start..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, index < scalars.count)
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
