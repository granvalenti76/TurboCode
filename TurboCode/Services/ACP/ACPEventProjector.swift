import Foundation

/// Converts normalized Core events into ACP `session/update` payloads. The
/// projector owns only wire presentation: tool execution, approval policy,
/// and model decisions remain in the injected application runtime.
actor ACPEventProjector {
    private var assistantSnapshots: [TurnID: String] = [:]
    private var messageSequences: [TurnID: Int] = [:]

    func update(
        for event: AgentRuntimeEvent,
        sessionID: String
    ) -> ACPAgentUpdate? {
        switch event {
        case .assistantTextChanged(let turnID, let text):
            return assistantUpdate(turnID: turnID, text: text, sessionID: sessionID)
        case .toolStarted(let call):
            return ACPAgentUpdate(
                sessionID: sessionID,
                update: .object([
                    "sessionUpdate": .string("tool_call"),
                    "toolCallId": .string(call.id),
                    "title": .string(call.name),
                    "kind": .string("other"),
                    "status": .string("pending")
                ])
            )
        case .toolFinished(let result):
            let status: String
            switch result.status {
            case .succeeded: status = "completed"
            case .failed: status = "failed"
            case .cancelled: status = "cancelled"
            }
            let output = result.errorMessage ?? result.output
            var payload: [String: MCPJSONValue] = [
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string(result.id),
                "status": .string(status)
            ]
            if !output.isEmpty {
                payload["content"] = .array([
                    .object([
                        "type": .string("content"),
                        "content": .object([
                            "type": .string("text"),
                            "text": .string(output)
                        ])
                    ])
                ])
            }
            return ACPAgentUpdate(sessionID: sessionID, update: .object(payload))
        case .usageUpdated(_, _, let context, _):
            guard let context else { return nil }
            return ACPAgentUpdate(
                sessionID: sessionID,
                update: .object([
                    "sessionUpdate": .string("usage_update"),
                    "used": .number(Double(context.usedTokens)),
                    "size": .number(Double(context.contextSize))
                ])
            )
        case .started, .phaseChanged, .reasoningTextChanged,
             .approvalRequested, .completed:
            // ACP has no stable baseline update for these Core events. In
            // particular, reasoning and approvals need separate negotiated
            // capabilities/client requests and must not be guessed as text.
            return nil
        }
    }

    /// Releases cumulative text state after terminal settlement so a long-lived
    /// ACP helper does not retain every completed turn indefinitely.
    func finish(turnID: TurnID) {
        assistantSnapshots.removeValue(forKey: turnID)
        messageSequences.removeValue(forKey: turnID)
    }

    private func assistantUpdate(
        turnID: TurnID,
        text: String,
        sessionID: String
    ) -> ACPAgentUpdate? {
        let previous = assistantSnapshots[turnID] ?? ""
        let delta: String
        if text.hasPrefix(previous) {
            delta = String(text.dropFirst(previous.count))
        } else {
            messageSequences[turnID, default: 0] += 1
            delta = text
        }
        assistantSnapshots[turnID] = text
        guard !delta.isEmpty else { return nil }

        let sequence = messageSequences[turnID, default: 0]
        let messageID = "msg-\(turnID.rawValue)-\(sequence)"
        return ACPAgentUpdate(
            sessionID: sessionID,
            update: .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "messageId": .string(messageID),
                "content": .object([
                    "type": .string("text"),
                    "text": .string(delta)
                ])
            ])
        )
    }
}
