import Foundation
import Testing
@testable import TurboCode

@Suite("Codex profile")
struct CodexProfileTests {
    @Test("Thread start uses the App Server workspace sandbox wire value")
    func threadStartUsesWorkspaceSandboxWireValue() {
        #expect(CodexAppServerClient.workspaceSandbox == "workspace-write")
    }

    @Test("Codex is not sendable before its runtime is ready")
    @MainActor
    func codexIsNotSendableBeforeRuntimeIsReady() {
        let store = ChatStore()
        store.activeBackend = .codex

        store.codexConnectionState = .connecting
        #expect(!store.activeProfileCanSend)

        store.codexConnectionState = .signedOut
        #expect(!store.activeProfileCanSend)

        store.codexConnectionState = .ready(planType: "plus")
        #expect(store.activeProfileCanSend)
    }

    @Test("RPC timeout identifies the unresponsive App Server method")
    func rpcTimeoutIdentifiesMethod() {
        let error = CodexAppServerError.requestTimedOut(
            method: "model/list",
            serverDetail: "runtime unavailable"
        )

        #expect(error.localizedDescription.contains("model/list"))
        #expect(error.localizedDescription.contains("20 seconds"))
        #expect(error.localizedDescription.contains("runtime unavailable"))
    }

    @Test("Luna catalog preserves every supported reasoning effort")
    func lunaCatalogPreservesReasoningEfforts() throws {
        let data = Data(
            """
            {
              "id": "gpt-5.6-luna",
              "model": "gpt-5.6-luna",
              "displayName": "GPT-5.6-Luna",
              "description": "Fast and affordable agentic coding model.",
              "supportedReasoningEfforts": [
                {"reasoningEffort":"low","description":"Fast"},
                {"reasoningEffort":"medium","description":"Balanced"},
                {"reasoningEffort":"high","description":"Deep"},
                {"reasoningEffort":"xhigh","description":"Extra deep"},
                {"reasoningEffort":"max","description":"Maximum"}
              ],
              "defaultReasoningEffort": "medium"
            }
            """.utf8
        )

        let model = try JSONDecoder().decode(
            CodexModelDescriptor.self,
            from: data
        )

        #expect(model.id == CodexAppServerClient.lunaModelID)
        #expect(model.defaultReasoningEffort == .medium)
        #expect(
            model.supportedReasoningEfforts.map(\.reasoningEffort)
                == [.low, .medium, .high, .xhigh, .max]
        )
    }

    @Test("Codex reasoning labels match the composer language")
    func reasoningLabelsMatchComposerLanguage() {
        #expect(CodexReasoningEffort.low.displayName == "Light")
        #expect(CodexReasoningEffort.medium.displayName == "Medium")
        #expect(CodexReasoningEffort.xhigh.displayName == "Extra High")
        #expect(CodexReasoningEffort.max.displayName == "Max")
        #expect(CodexReasoningEffort.ultra.displayName == "Ultra")
    }

    @Test("Catalog decoding accepts reasoning levels used by other models")
    func catalogDecodingAcceptsOtherModelReasoningLevels() throws {
        let data = Data(
            """
            {
              "data": [
                {
                  "id": "gpt-5.6-sol",
                  "model": "gpt-5.6-sol",
                  "displayName": "GPT-5.6-Sol",
                  "description": "Frontier model.",
                  "supportedReasoningEfforts": [
                    {"reasoningEffort":"low","description":"Fast"},
                    {"reasoningEffort":"ultra","description":"Delegated"}
                  ],
                  "defaultReasoningEffort": "low"
                },
                {
                  "id": "gpt-5.6-luna",
                  "model": "gpt-5.6-luna",
                  "displayName": "GPT-5.6-Luna",
                  "description": "Fast and affordable.",
                  "supportedReasoningEfforts": [
                    {"reasoningEffort":"medium","description":"Balanced"}
                  ],
                  "defaultReasoningEffort": "medium"
                }
              ]
            }
            """.utf8
        )

        let catalog = try JSONDecoder().decode(
            CodexModelListResult.self,
            from: data
        )

        #expect(catalog.data.count == 2)
        #expect(catalog.data.last?.id == CodexAppServerClient.lunaModelID)
    }

    @Test("App Server pipe chunks preserve partial JSONL records")
    func appServerPipeChunksPreservePartialRecords() {
        var buffer = Data()

        let first = CodexAppServerClient.framedLines(
            from: Data(#"{"id":1,"res"#.utf8),
            buffer: &buffer
        )
        let second = CodexAppServerClient.framedLines(
            from: Data(
                """
                ult":{}}\r
                {"method":"turn/completed"}
                """.utf8
            ),
            buffer: &buffer
        )

        #expect(first.isEmpty)
        #expect(second == [#"{"id":1,"result":{}}"#])
        #expect(
            String(data: buffer, encoding: .utf8)
                == #"{"method":"turn/completed"}"#
        )
    }

    @Test("Codex command approvals retain the server request identifier")
    func commandApprovalRetainsRequestIdentifier() {
        let request = CodexAppServerClient.approvalRequest(
            id: .string("approval-7"),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "command": .string("xcodebuild test"),
                "cwd": .string("/workspace"),
                "reason": .string("Run the test suite")
            ])
        )

        #expect(request?.presentationID == "codex-approval-7")
        #expect(request?.operation == "command")
        #expect(request?.path == "/workspace")
        #expect(
            request?.acceptedResult
                == .object(["decision": .string("accept")])
        )
        #expect(
            request?.declinedResult
                == .object(["decision": .string("decline")])
        )
    }

    @Test("Codex permission denial grants no additional access")
    func permissionDenialGrantsNoAdditionalAccess() {
        let request = CodexAppServerClient.approvalRequest(
            id: .integer(11),
            method: "item/permissions/requestApproval",
            params: .object([
                "cwd": .string("/workspace"),
                "permissions": .object([
                    "network": .object(["enabled": .bool(true)])
                ])
            ])
        )

        #expect(
            request?.declinedResult == .object([
                "permissions": .object([:]),
                "scope": .string("turn")
            ])
        )
    }
}
