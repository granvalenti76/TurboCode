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
        // This is a runtime fixture, so seed the bounded owners directly
        // instead of exposing a façade mutation path.
        store.modelRuntimeStore.activeBackend = .codex

        store.codexRuntimeStore.connectionState = .connecting
        #expect(!store.activeProfileCanSend)

        store.codexRuntimeStore.connectionState = .signedOut
        #expect(!store.activeProfileCanSend)

        store.codexRuntimeStore.connectionState = .ready(planType: "plus")
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

    @Test("Codex context threshold uses latest usage rather than cumulative traffic")
    func codexContextThresholdUsesLatestUsage() {
        let usage = CodexAppServerClient.tokenUsage(
            from: .object([
                "tokenUsage": .object([
                    "last": .object(["totalTokens": .integer(9_800)]),
                    "total": .object(["totalTokens": .integer(48_000)]),
                    "modelContextWindow": .integer(114_688)
                ])
            ])
        )

        #expect(usage?.lastTotalTokens == 9_800)
        #expect(usage?.cumulativeTotalTokens == 48_000)
        #expect(usage?.modelContextWindow == 114_688)
        #expect(
            !RuntimeContextHandoff.shouldSummarizeCodexContext(
                lastTotalTokens: usage?.lastTotalTokens
            )
        )
        #expect(
            RuntimeContextHandoff.shouldSummarizeCodexContext(
                lastTotalTokens: 10_001
            )
        )
    }

    @Test("Runtime handoff excludes reasoning and retains widget outcomes")
    @MainActor
    func runtimeHandoffFiltersPresentationNoise() {
        let listing = WorkspaceListingBlock(
            toolCallID: "call-1",
            path: ".",
            entries: [
                WorkspaceListingEntry(
                    name: "App.swift",
                    relativePath: "TurboCode/App.swift",
                    kind: .file,
                    sizeBytes: 128,
                    modifiedAt: nil,
                    fileExtension: "swift"
                )
            ],
            totalCount: 1,
            isTruncated: false,
            errorMessage: nil
        )
        let boundary = ChatBlock(
            id: "boundary",
            kind: .assistant,
            text: "Already known by Codex"
        )
        let blocks = [
            boundary,
            ChatBlock(kind: .reasoning, text: "private chain of thought"),
            ChatBlock(kind: .user, text: "Inspect the project"),
            ChatBlock(
                kind: .workspaceListing,
                text: "",
                workspaceListing: listing
            )
        ]

        let rendered = RuntimeContextHandoff.render(
            blocks: blocks,
            after: boundary.id
        )

        #expect(!rendered.contains("Already known"))
        #expect(!rendered.contains("private chain"))
        #expect(rendered.contains("USER:\nInspect the project"))
        #expect(rendered.contains("TurboCode/App.swift"))
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

    @Test("Codex catalog honors selection and keeps deterministic fallbacks")
    func codexCatalogSelectionUsesPreferredThenLunaThenFirst() throws {
        let options = [
            CodexReasoningOption(
                reasoningEffort: .medium,
                description: "Balanced"
            )
        ]
        let sol = CodexModelDescriptor(
            id: "gpt-5.6-sol",
            model: "gpt-5.6-sol",
            displayName: "Sol",
            description: "Frontier",
            supportedReasoningEfforts: options,
            defaultReasoningEffort: .medium
        )
        let luna = CodexModelDescriptor(
            id: CodexAppServerClient.lunaModelID,
            model: CodexAppServerClient.lunaModelID,
            displayName: "Luna",
            description: "Efficient",
            supportedReasoningEfforts: options,
            defaultReasoningEffort: .medium
        )

        #expect(
            CodexAppServerClient.selectModel(
                from: [sol, luna],
                preferredID: sol.id
            )?.id == sol.id
        )
        #expect(
            CodexAppServerClient.selectModel(
                from: [sol, luna],
                preferredID: "unavailable"
            )?.id == luna.id
        )
        #expect(
            CodexAppServerClient.selectModel(
                from: [sol],
                preferredID: nil
            )?.id == sol.id
        )
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

    @Test("Codex runtime failures are not labeled malformed responses")
    func codexRuntimeFailuresHaveAnOperationalErrorMessage() {
        let error = CodexAppServerError.turnFailed(
            "Selected model is at capacity. Please try a different model."
        )

        #expect(
            error.localizedDescription
                == "Codex turn failed: Selected model is at capacity. "
                    + "Please try a different model."
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

    @Test("Codex dynamic tool request retains structured arguments")
    func dynamicToolRequestRetainsStructuredArguments() {
        let request = CodexAppServerClient.dynamicToolCall(
            id: .integer(41),
            params: .object([
                "callId": .string("call-7"),
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "tool": .string("list_workspace"),
                "arguments": .object(["path": .string("TurboCode")])
            ])
        )

        #expect(request?.rpcID == .integer(41))
        #expect(request?.callID == "call-7")
        #expect(request?.tool == "list_workspace")
        #expect(request?.arguments["path"]?.stringValue == "TurboCode")
    }

    @Test("Codex exposes the TurboCode tools with native presentations")
    func codexExposesNativePresentationTools() {
        let specs = CodexTurboCodeToolBridge.specifications(
            workspaceRoot: "/workspace",
            agentTuning: .default
        )
        let names = Set(specs.map(\.name))

        #expect(names.contains("list_workspace"))
        #expect(names.contains("ripgrep"))
        #expect(names.contains("apply_edits"))
        #expect(names.contains("git"))
        #expect(names.contains("swift_package_manager"))
        #expect(names.contains("create_skill"))
        #expect(
            specs.allSatisfy {
                $0.inputSchema["type"]?.stringValue == "object"
            }
        )
    }

    @Test("Codex list workspace calls the native listing pipeline")
    func codexListWorkspaceCallsNativeListingPipeline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello".utf8).write(
            to: root.appendingPathComponent("Example.txt")
        )
        let call = CodexDynamicToolCall(
            rpcID: .integer(9),
            callID: "call-9",
            tool: "list_workspace",
            arguments: .object(["path": .string(".")])
        )

        let execution = try await CodexTurboCodeToolBridge.execute(
            call,
            workspaceRoot: root.path,
            workspaceName: "Fixture",
            agentTuning: .default
        )

        #expect(execution.result.succeeded)
        guard case .workspaceListing(let listing) = execution.presentation else {
            Issue.record("Expected a workspace listing presentation")
            return
        }
        #expect(listing.toolCallID == "call-9")
        #expect(listing.entries.map(\.name) == ["Example.txt"])
        #expect(listing.workspaceName == "Fixture")
    }

    @Test("Codex executes the shared Swift Package Manager wrapper")
    func codexExecutesSwiftPackageManager() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "CodexFixture")
        """.write(
            to: root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let call = CodexDynamicToolCall(
            rpcID: .integer(10),
            callID: "call-10",
            tool: "swift_package_manager",
            arguments: .object(["action": .string("dumpPackage")])
        )

        let execution = try await CodexTurboCodeToolBridge.execute(
            call,
            workspaceRoot: root.path,
            workspaceName: "CodexFixture",
            agentTuning: .default
        )

        #expect(execution.result.succeeded)
        #expect(execution.result.text.contains("Exit code: 0"))
        #expect(execution.result.text.contains("CodexFixture"))
    }

    @Test("Codex advertises and loads discovered skills")
    @MainActor
    func codexAdvertisesAndLoadsDiscoveredSkills() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let skillURL = root.appendingPathComponent("SKILL.md")
        try """
        ---
        name: release-notes
        description: Prepare concise release notes.
        ---
        Keep the release notes factual and grouped by user impact.
        """.write(to: skillURL, atomically: true, encoding: .utf8)
        let skill = try TurboCodeSkillDefinition(contentsOf: skillURL)

        let specs = CodexTurboCodeToolBridge.specifications(
            workspaceRoot: root.path,
            agentTuning: .default,
            availableSkills: [skill]
        )
        #expect(specs.map(\.name).contains("load_skill"))

        let call = CodexDynamicToolCall(
            rpcID: .integer(12),
            callID: "call-skill",
            tool: "load_skill",
            arguments: .object(["name": .string(skill.name)])
        )
        let execution = try await CodexTurboCodeToolBridge.execute(
            call,
            workspaceRoot: root.path,
            workspaceName: "Fixture",
            agentTuning: .default,
            availableSkills: [skill]
        )

        #expect(execution.result.succeeded)
        #expect(execution.result.text.contains(skill.prompt))

        let createCall = CodexDynamicToolCall(
            rpcID: .integer(13),
            callID: "call-create-skill",
            tool: "create_skill",
            arguments: .object([
                "name": .string("workspace-review"),
                "description": .string("Review workspace changes before handoff."),
                "instructions": .string("Inspect the diff and summarize user-visible impact.")
            ])
        )
        let createExecution = try await CodexTurboCodeToolBridge.execute(
            createCall,
            workspaceRoot: root.path,
            workspaceName: "Fixture",
            agentTuning: .default,
            availableSkills: [skill]
        )
        #expect(createExecution.result.succeeded)
        let createdURL = root
            .appendingPathComponent(".agents/skills/workspace-review/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: createdURL.path))
        #expect(try TurboCodeSkillDefinition(contentsOf: createdURL).name == "workspace-review")
    }
}
