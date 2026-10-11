import Foundation
import FoundationModels
import Synchronization
import Testing
@testable import TurboCode

/// The Cowork tool boundary: VM tools never reach Coding sessions, host tools
/// never reach Cowork sessions, and the VM tools drive the runtime correctly.
@Suite("Cowork session tools")
struct CoworkSessionToolsTests {
    /// Every capability that can read or change the Mac.
    static let hostCapabilities: Set<ToolCapabilityID> = Set(ToolCapabilityID.allCases)
        .subtracting([.vmExec, .vmFile, .vmExport, .turboCodeGuide, .loadSkill])

    // MARK: Catalog boundary

    @Test("No Coding plan ever registers a VM tool, even when everything is selected")
    func codingPlansNeverContainVMTools() {
        let context = ToolAccessContext(
            hasWorkspace: true,
            hasSkills: true,
            safariMCPEnabled: true,
            xcodeMCPEnabled: true,
            hasDelegateModel: true,
            repositoryMapDetail: .enhanced
        )
        let profiles: [ModelRuntimeProfile] = [.microtask, .standalone, .orchestrator, .delegate]
        let tiers: [ModelToolTier] = [.onDevice, .standard, .enhanced]
        for profile in profiles {
            for tier in tiers {
                for selection in [nil, Set(ToolCapabilityID.allCases)] {
                    let plan = ModelToolCatalog.plan(
                        profile: profile, tier: tier, context: context, selectedIDs: selection
                    )
                    #expect(plan.registeredIDs.allSatisfy { !$0.isCoworkVMTool },
                            "\(profile) \(tier) selection: \(selection == nil ? "default" : "all")")
                }
            }
        }
    }

    @Test("The Cowork plan contains the VM tools and nothing that touches the Mac")
    func coworkPlanExcludesHostCapabilities() {
        let context = ToolAccessContext(
            hasWorkspace: true,
            hasSkills: true,
            safariMCPEnabled: true,
            xcodeMCPEnabled: true,
            hasDelegateModel: true,
            repositoryMapDetail: .enhanced
        )
        for tier in [ModelToolTier.onDevice, .standard, .enhanced] {
            let plan = ModelToolCatalog.coworkPlan(tier: tier, context: context)
            #expect(plan.registeredIDs.isSuperset(of: [.vmExec, .vmFile, .vmExport]))
            #expect(plan.registeredIDs.isDisjoint(with: Self.hostCapabilities))
        }
    }

    @Test("VM tools are hidden from host tool lists but still describable")
    func vmToolsStayOutOfHostDescriptors() {
        #expect(!ModelToolCatalog.descriptors.contains { $0.id.isCoworkVMTool })
        #expect(ModelToolCatalog.descriptor(for: .vmExec).name == "VM Command")
        #expect(ModelToolCatalog.descriptor(for: .vmFile).name == "VM Files")
    }

    @Test("A Cowork session registers only VM tools, even with plugins, Safari, and extra tools enabled")
    @MainActor
    func coworkSessionRegistersOnlyVMTools() throws {
        var tuning = AgentTuningConfig.default
        tuning.experimental.safariMCPEnabled = true
        tuning.experimental.thirdPartyPluginsEnabled = true
        let session = ModelSessionFactory.makeSession(
            configuration: ModelSessionConfiguration(
                backend: .llamaServer,
                activeRemoteModel: .fallbackLlama,
                delegateRemoteModel: .fallbackLlama,
                orchestratorMode: .standalone,
                workspaceRoot: "",
                agentTuning: tuning,
                availableSkills: [],
                documentationStore: .live,
                activeDynamicProfile: nil,
                reasoningEffort: nil,
                delegateReasoningEffort: nil,
                activeTemperature: nil,
                delegateTemperature: nil,
                delegateToolIDs: nil,
                dropsCompletedToolCalls: false,
                workspaceInstructions: nil,
                cowork: Self.context(runtime: RecordingRuntime())
            ),
            history: [],
            events: ModelSessionEvents(
                toolStarted: { _, _, _ in },
                toolFinished: { _, _, _, _ in },
                delegationChanged: { _ in },
                additionalTools: [ListWorkspaceTool(workspaceRoot: "/tmp/workspace")]
            )
        )
        let entry = try #require(session.transcript.first)
        guard case .instructions(let instructions) = entry else {
            Issue.record("Expected session instructions")
            return
        }
        #expect(Set(instructions.toolDefinitions.map(\.name)) == ["turbocode_guide", "vm_exec", "vm_file", "vm_export"])
    }

    // MARK: Admission

    @Test("Cowork turns are admitted only with a ready VM and a non-Codex backend")
    func admissionRules() {
        #expect(CoworkAdmission.evaluate(domain: .coding, backend: .codex, hasContext: false) == .allowed)
        #expect(CoworkAdmission.evaluate(domain: .cowork, backend: .codex, hasContext: true)
            == .rejected(CoworkAdmission.codexMessage))
        #expect(CoworkAdmission.evaluate(domain: .cowork, backend: .llamaServer, hasContext: false)
            == .rejected(CoworkAdmission.unavailableMessage))
        for backend in [ModelBackend.foundationApple, .llamaServer, .premium] {
            #expect(CoworkAdmission.evaluate(domain: .cowork, backend: backend, hasContext: true) == .allowed)
        }
    }

    // MARK: Prompt

    @Test("Only Cowork prompts describe the VM, and they omit the host workspace")
    func coworkPromptSection() {
        func prompt(_ cowork: CoworkPromptFacts?, workspace: String) -> String {
            TurboCodeSystemPromptBuilder.build(TurboCodeSystemPromptContext(
                role: .standalone,
                backend: .llamaServer,
                workspaceRoot: workspace,
                agentTuning: .default,
                toolIDs: [.vmExec, .vmFile],
                toolNames: ["vm_exec", "vm_file"],
                availableSkills: [],
                workspaceInstructions: nil,
                cowork: cowork
            ))
        }
        let cowork = prompt(.init(sessionDirectory: "/home/cowork/sessions/abc", sharesInputFolder: false), workspace: "")
        #expect(cowork.contains("Cowork VM:"))
        #expect(cowork.contains("/home/cowork/sessions/abc"))
        #expect(cowork.contains("No user folder is shared"))
        #expect(!cowork.contains("Workspace:\n"))
        #expect(!cowork.contains("native macOS coding agent"))

        let shared = prompt(.init(sessionDirectory: "/home/cowork/sessions/abc", sharesInputFolder: true), workspace: "")
        #expect(shared.contains("/work: the user's shared folder, read-only"))

        #expect(!prompt(nil, workspace: "/tmp/project").contains("Cowork VM:"))
    }

    // MARK: Tools against a fake runtime

    @Test("vm_exec boots the VM lazily and runs as the agent in the session directory")
    func vmExecRunsInSessionDirectory() async throws {
        let runtime = RecordingRuntime(stdout: "v24.21.0\n")
        let tool = VMExecTool(context: Self.context(runtime: runtime))

        let output = try await tool.call(arguments: VMExecArguments(
            command: "node -v", workingDirectory: nil, timeoutSeconds: 99_999
        ))

        #expect(output.hasPrefix("Exit code 0"))
        #expect(output.contains("v24.21.0"))
        #expect(await runtime.startCount == 1)
        let request = try #require(await runtime.requests.first)
        #expect(request.user == .agent)
        #expect(request.script.contains("mkdir -p '/home/cowork/sessions/session-1'"))
        #expect(request.script.contains("cd -- '/home/cowork/sessions/session-1'"))
        #expect(request.script.contains("node -v"))
        // Model-supplied timeouts are clamped to the tool maximum.
        #expect(request.timeout == .seconds(VMExecTool.maximumTimeoutSeconds))
    }

    @Test("vm_file writes content through stdin, never through the script")
    func vmFileWritesThroughStdin() async throws {
        let runtime = RecordingRuntime()
        let tool = VMFileTool(context: Self.context(runtime: runtime))
        let content = "line 1\n'; rm -rf / #\n$(whoami)\n"

        let output = try await tool.call(arguments: VMFileArguments(
            action: "write", path: "notes/draft.md", content: content,
            startLine: nil, lineCount: nil, depth: nil
        ))

        #expect(output.hasPrefix("Wrote"))
        // The first exec reads the previous version for the diff; the write
        // is the one carrying stdin.
        let request = try #require(await runtime.requests.first { $0.stdin != nil })
        #expect(request.stdin == Data(content.utf8))
        #expect(!request.script.contains("whoami"))
        #expect(request.script.contains("'/home/cowork/sessions/session-1/notes/draft.md'"))
    }

    @Test("A text write publishes a display-only Cowork diff receipt")
    func vmFileWritePublishesCoworkDiff() async throws {
        let runtime = RecordingRuntime(stdout: "Hello\nold line\n")
        let registry = ToolReceiptRegistry()
        let tool = VMFileTool(context: Self.context(runtime: runtime), receiptRegistry: registry)

        let output = try await tool.call(arguments: VMFileArguments(
            action: "write", path: "notes/draft.md", content: "Hello\nnew line\n",
            startLine: nil, lineCount: nil, depth: nil
        ))

        let token = try #require(output.receiptToken)
        guard case .diffPatch(let receipt) = try #require(await registry.take(token)) else {
            Issue.record("Expected a diff receipt")
            return
        }
        #expect(receipt.block.isCoworkVM)
        #expect(receipt.block.files.first?.path == "notes/draft.md")
        #expect(receipt.block.additions == 1)
        #expect(receipt.block.deletions == 1)
        #expect(receipt.block.reviewFiles?.first?.originalText == "Hello\nold line\n")
        #expect(receipt.block.reviewFiles?.first?.modifiedText == "Hello\nnew line\n")
    }

    @Test("vm_export lists exportable deliverables without build folders or links")
    func vmExportListsDeliverables() async throws {
        let outbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outbox) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outbox.appendingPathComponent("site/node_modules/x"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outbox.appendingPathComponent("site/node_modules/x/index.js"))
        try Data("<h1>hi</h1>".utf8).write(to: outbox.appendingPathComponent("site/index.html"))
        try Data("png".utf8).write(to: outbox.appendingPathComponent("shot.png"))
        try fileManager.createSymbolicLink(
            at: outbox.appendingPathComponent("hosts"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )
        let context = CoworkSessionContext(
            runtime: RecordingRuntime(),
            configuration: CoworkVMConfiguration(outbox: outbox),
            sessionID: "session-1"
        )

        #expect(CoworkExportPlanner.deliverables(in: outbox).map(\.path) == ["shot.png", "site/index.html"])
        let output = try await VMExportTool(context: context).call(arguments: VMExportArguments(summary: nil))
        #expect(output.hasPrefix("2 deliverables"))
        #expect(output.contains("- site/index.html"))
        #expect(!output.contains("node_modules"))
        #expect(!output.contains("hosts"))

        let empty = CoworkSessionContext(
            runtime: RecordingRuntime(),
            configuration: CoworkVMConfiguration(outbox: outbox.appendingPathComponent("missing")),
            sessionID: "session-2"
        )
        #expect(try await VMExportTool(context: empty).call(arguments: VMExportArguments(summary: nil))
            .hasPrefix("No deliverables"))
    }

    @Test("vm_file rejects oversized writes before reaching the VM")
    func vmFileRejectsOversizedWrites() async throws {
        let runtime = RecordingRuntime()
        let tool = VMFileTool(context: Self.context(runtime: runtime))
        let content = String(repeating: "x", count: VMFileTool.maximumWriteBytes + 1)

        let output = try await tool.call(arguments: VMFileArguments(
            action: "write", path: "big.txt", content: content,
            startLine: nil, lineCount: nil, depth: nil
        ))

        #expect(output.contains("limit"))
        #expect(await runtime.requests.isEmpty)
        #expect(await runtime.startCount == 0)
    }

    @Test("Guest paths resolve from the session directory and IDs are sanitized")
    func guestPathResolution() {
        let context = Self.context(runtime: RecordingRuntime())
        #expect(context.guestPath(nil) == "/home/cowork/sessions/session-1")
        #expect(context.guestPath("site/index.html") == "/home/cowork/sessions/session-1/site/index.html")
        #expect(context.guestPath("/out/report.pdf") == "/out/report.pdf")
        #expect(context.guestPath("~/notes.md") == "/home/cowork/notes.md")

        let hostile = CoworkSessionContext(
            runtime: RecordingRuntime(),
            configuration: CoworkVMConfiguration(outbox: URL(fileURLWithPath: "/tmp/outbox")),
            sessionID: "../../etc;rm"
        )
        #expect(hostile.sessionDirectory == "/home/cowork/sessions/etcrm")
        #expect(CoworkShell.quote("it's") == "'it'\\''s'")
    }

    @Test("Long output keeps its beginning and end and states what was omitted")
    func outputTruncation() {
        let long = String(repeating: "a", count: 5_000) + String(repeating: "z", count: 10_000)
        let text = CoworkOutputFormatter.truncate(long)
        #expect(text.hasPrefix(String(repeating: "a", count: CoworkOutputFormatter.headCharacters)))
        #expect(text.hasSuffix(String(repeating: "z", count: CoworkOutputFormatter.tailCharacters)))
        #expect(text.contains("6000 characters omitted"))

        var timedOut = CoworkExecResult()
        timedOut.timedOut = true
        #expect(CoworkOutputFormatter.render(timedOut).hasPrefix("Timed out"))
    }

    // MARK: Helpers

    static func context(runtime: RecordingRuntime) -> CoworkSessionContext {
        CoworkSessionContext(
            runtime: runtime,
            configuration: CoworkVMConfiguration(outbox: URL(fileURLWithPath: "/tmp/cowork-outbox")),
            sessionID: "session-1"
        )
    }
}

/// Records requests and replies with a fixed successful result.
actor RecordingRuntime: CoworkVMRuntime {
    private let stdout: String
    private(set) var requests: [CoworkExecRequest] = []
    private(set) var startCount = 0
    private var running: CoworkVMConfiguration?

    init(stdout: String = "") {
        self.stdout = stdout
    }

    func start(_ configuration: CoworkVMConfiguration) async throws {
        startCount += 1
        running = configuration
    }

    func exec(_ request: CoworkExecRequest) async throws -> AsyncThrowingStream<CoworkExecEvent, any Error> {
        requests.append(try request.validated())
        let output = stdout
        return AsyncThrowingStream { continuation in
            if !output.isEmpty { continuation.yield(.stdout(Data(output.utf8))) }
            continuation.yield(.exited(0))
            continuation.finish()
        }
    }

    func stop() async throws { running = nil }
    func reset() async throws { running = nil }
    func state() async -> CoworkVMState { running.map(CoworkVMState.running) ?? .stopped }
}
