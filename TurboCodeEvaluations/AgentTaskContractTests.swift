import Foundation
import Testing
@testable import TurboCode

@Suite("Agent task contract")
struct AgentTaskContractTests {
    @Test("Task and result round-trip without losing typed fields")
    func roundTripsTaskAndResult() throws {
        let envelope = try AgentTaskEnvelope(
            taskID: "task-42",
            attemptID: "attempt-1",
            mode: .coding,
            goal: "Add a focused Swift parser.",
            acceptanceCriteria: [
                "The parser accepts valid input.",
                "The focused tests pass."
            ],
            suggestedScope: ["TurboCode/Services/Parser.swift"],
            verificationRequest: .test,
            verificationParameters: AgentVerificationParameters(
                containerPath: "TurboCode.xcodeproj",
                scheme: "TurboCodeEvaluations",
                configuration: "Debug",
                destination: "platform=macOS"
            ),
            budget: DelegationBudget(timeoutSeconds: 90, maximumToolCalls: 8)
        )
        let result = try AgentTaskResult(
            taskID: envelope.taskID,
            attemptID: envelope.attemptID,
            outcome: .verified,
            technicalSummary: "Added the parser and ran its focused tests.",
            receiptIDs: ["edit-1", "test-1", "edit-1"],
            verification: AgentVerificationResult(
                status: .passed,
                receiptID: "test-1"
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decodedEnvelope = try JSONDecoder().decode(
            AgentTaskEnvelope.self,
            from: encoder.encode(envelope)
        )
        let decodedResult = try JSONDecoder().decode(
            AgentTaskResult.self,
            from: encoder.encode(result)
        )

        #expect(decodedEnvelope == envelope)
        #expect(decodedEnvelope.mode == .coding)
        #expect(decodedEnvelope.verificationParameters?.scheme == "TurboCodeEvaluations")
        #expect(decodedResult == result)
        #expect(decodedResult.receiptIDs == ["edit-1", "test-1"])
    }

    @Test("Legacy transport defaults newly introduced optional fields")
    func decodesMinimalCompatibilityPayloads() throws {
        let envelopeData = try #require(
            """
            {
              "taskID": "task-legacy",
              "attemptID": "attempt-legacy",
              "goal": "Inspect one file.",
              "acceptanceCriteria": ["Return a concise finding."]
            }
            """.data(using: .utf8)
        )
        let resultData = try #require(
            """
            {
              "taskID": "task-legacy",
              "attemptID": "attempt-legacy",
              "outcome": "completed",
              "technicalSummary": "Inspection completed."
            }
            """.data(using: .utf8)
        )

        let envelope = try JSONDecoder().decode(AgentTaskEnvelope.self, from: envelopeData)
        let result = try JSONDecoder().decode(AgentTaskResult.self, from: resultData)

        #expect(envelope.schemaVersion == 2)
        #expect(envelope.mode == .coding)
        #expect(envelope.verificationRequest == .none)
        #expect(envelope.verificationParameters == nil)
        #expect(envelope.budget == .default)
        #expect(result.schemaVersion == 1)
        #expect(result.receiptIDs.isEmpty)
        #expect(result.verification.status == .notRequested)
        #expect(result.unresolvedWork.isEmpty)
    }

    @Test("Invalid task budgets and ambiguous goals are rejected")
    func rejectsInvalidEnvelopes() {
        #expect(throws: AgentTaskContractError.emptyField("goal")) {
            try AgentTaskEnvelope(
                taskID: "task",
                attemptID: "attempt",
                goal: "  ",
                acceptanceCriteria: ["Compiles"]
            )
        }
        #expect(throws: AgentTaskContractError.invalidTimeout(0)) {
            try AgentTaskEnvelope(
                taskID: "task",
                attemptID: "attempt",
                goal: "Make a local edit.",
                acceptanceCriteria: ["Compiles"],
                budget: DelegationBudget(timeoutSeconds: 0, maximumToolCalls: 1)
            )
        }
        #expect(throws: AgentTaskContractError.missingAcceptanceCriteria) {
            try AgentTaskEnvelope(
                taskID: "task",
                attemptID: "attempt",
                goal: "Make a local edit.",
                acceptanceCriteria: []
            )
        }
        #expect(throws: AgentTaskContractError.verificationParametersWithoutRequest) {
            try AgentTaskEnvelope(
                taskID: "task",
                attemptID: "attempt",
                goal: "Make a local edit.",
                acceptanceCriteria: ["Compiles"],
                verificationParameters: AgentVerificationParameters(
                    scheme: "TurboCode"
                )
            )
        }
        #expect(throws: AgentTaskContractError.textWorkerCannotVerify) {
            try AgentTaskEnvelope(
                taskID: "task",
                attemptID: "attempt",
                mode: .text,
                goal: "Write a summary.",
                acceptanceCriteria: ["The summary is concise."],
                verificationRequest: .test
            )
        }
    }

    @Test("Verified and failed outcomes require deterministic evidence")
    func rejectsInvalidResults() {
        #expect(throws: AgentTaskContractError.verifiedWithoutPassingVerification) {
            try AgentTaskResult(
                taskID: "task",
                attemptID: "attempt",
                outcome: .verified,
                technicalSummary: "The model says it is correct."
            )
        }
        #expect(throws: AgentTaskContractError.passingVerificationWithoutReceipt) {
            try AgentTaskResult(
                taskID: "task",
                attemptID: "attempt",
                outcome: .verified,
                technicalSummary: "Tests passed.",
                verification: AgentVerificationResult(status: .passed)
            )
        }
        #expect(throws: AgentTaskContractError.missingFailureReason) {
            try AgentTaskResult(
                taskID: "task",
                attemptID: "attempt",
                outcome: .failed,
                technicalSummary: "The worker stopped."
            )
        }
        #expect(throws: AgentTaskContractError.invalidTerminalState(.completed)) {
            try AgentTaskResult(
                taskID: "task",
                attemptID: "attempt",
                outcome: .completed,
                technicalSummary: "The model claims verification passed.",
                receiptIDs: ["invented-receipt"],
                verification: AgentVerificationResult(
                    status: .passed,
                    receiptID: "invented-receipt"
                )
            )
        }
    }

    @Test("Unknown schema versions fail closed during decoding")
    func rejectsUnknownSchemaVersion() throws {
        let data = try #require(
            """
            {
              "schemaVersion": 99,
              "taskID": "task",
              "attemptID": "attempt",
              "goal": "Inspect one file.",
              "acceptanceCriteria": ["Return a finding."]
            }
            """.data(using: .utf8)
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AgentTaskEnvelope.self, from: data)
        }
    }
}
