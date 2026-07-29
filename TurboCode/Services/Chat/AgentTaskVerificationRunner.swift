import Foundation
import FoundationModels

/// Immutable evidence produced after a worker and tied to its last mutation.
nonisolated struct AgentTaskVerificationReceipt: Sendable, Hashable {
    let id: String
    let request: VerificationRequest
    let mutationSequence: Int
    let succeeded: Bool
    let cancelled: Bool
    let summary: String
}

/// Deterministic verification boundary. Implementations execute developer
/// tooling; no model-generated text can satisfy this protocol.
nonisolated protocol AgentTaskVerificationRunning: Sendable {
    func verify(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        mutationSequence: Int
    ) async -> AgentTaskVerificationReceipt
}

/// Production Xcode verifier using the same native discovery and structured
/// xcresult parsing as the public Xcode tool.
nonisolated struct XcodeAgentTaskVerifier: AgentTaskVerificationRunning {
    let executionPolicy: ExecutionPolicy
    let enhancedOutput: Bool

    func verify(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        mutationSequence: Int
    ) async -> AgentTaskVerificationReceipt {
        let receiptID = "verification-\(envelope.attemptID)-\(UUID().uuidString)"
        do {
            try Task.checkCancellation()
            let execution = try await XcodeProjectService(
                workspaceRoot: context.workspaceRoot,
                executionPolicy: executionPolicy,
                enhancedOutput: enhancedOutput
            ).verification(
                request: envelope.verificationRequest,
                parameters: envelope.verificationParameters,
                timeoutSeconds: envelope.budget.timeoutSeconds
            )
            return AgentTaskVerificationReceipt(
                id: receiptID,
                request: envelope.verificationRequest,
                mutationSequence: mutationSequence,
                succeeded: execution.succeeded,
                cancelled: execution.cancelled,
                summary: execution.summary
            )
        } catch where error is CancellationError || Task.isCancelled {
            return AgentTaskVerificationReceipt(
                id: receiptID,
                request: envelope.verificationRequest,
                mutationSequence: mutationSequence,
                succeeded: false,
                cancelled: true,
                summary: "Verification was cancelled."
            )
        } catch {
            return AgentTaskVerificationReceipt(
                id: receiptID,
                request: envelope.verificationRequest,
                mutationSequence: mutationSequence,
                succeeded: false,
                cancelled: false,
                summary: error.localizedDescription
            )
        }
    }
}

/// Captures sequential worker mutation order without inspecting assistant prose.
actor AgentTaskMutationJournal {
    private(set) var sequence = 0
    private(set) var revisionConflictPath: String?

    func recordToolCompletion(_ event: AgentTaskToolOutputEvent) {
        if event.call.toolName == ToolCapabilityID.editFile.rawValue,
           let path = Self.revisionConflictPath(in: event.output) {
            revisionConflictPath = path
            return
        }
        guard Self.mutatingTools.contains(event.call.toolName) else { return }
        sequence += 1
    }

    private static func revisionConflictPath(
        in output: Transcript.ToolOutput
    ) -> String? {
        let text = output.segments.compactMap { segment -> String? in
            guard case .text(let value) = segment else { return nil }
            return value.content
        }.joined(separator: "\n")
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines)
                == "TURBOCODE_REVISION_CONFLICT" else {
            return nil
        }
        return lines
            .first(where: { $0.hasPrefix("path: ") })
            .map { String($0.dropFirst("path: ".count)) }
    }

    private static let mutatingTools: Set<String> = [
        ToolCapabilityID.editFile.rawValue,
        ToolCapabilityID.writeOnDevice.rawValue,
        ToolCapabilityID.removeFile.rawValue,
        ToolCapabilityID.fileSystem.rawValue
    ]
}
