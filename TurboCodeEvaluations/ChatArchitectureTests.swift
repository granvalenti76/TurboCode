import AppKit
import Observation
import SwiftUI
import Testing
@testable import TurboCode

@MainActor
@Suite("Chat architecture boundaries", .serialized)
struct ChatArchitectureTests {
    @Test("Composer view model owns and resets transient input")
    func composerProjectionOwnsDraftState() {
        let composer = ComposerViewModel()
        composer.messageText = "Inspect the runtime boundary"
        composer.mode = .plan

        #expect(composer.canSend)
        composer.reset()
        #expect(composer.messageText.isEmpty)
        #expect(!composer.canSend)
        #expect(composer.mode == .plan)
    }

    @Test("Presentation view model replaces and clears compaction notices")
    func presentationProjectionOwnsTransientNotice() {
        let presentation = ChatPresentationViewModel()
        let first = LocalCompactionNotice(
            sourceCharacters: 12_000,
            retainedCharacters: 3_000
        )
        let replacement = LocalCompactionNotice(
            sourceCharacters: 20_000,
            retainedCharacters: 4_000
        )

        presentation.presentCompactionNotice(first)
        presentation.presentCompactionNotice(replacement)
        #expect(presentation.localCompactionNotice == replacement)

        presentation.clearCompactionNotice()
        #expect(presentation.localCompactionNotice == nil)
    }

    @Test("Workbench profile presentation preserves the underlying route")
    func workbenchProfilePresentationIsModal() {
        let workbench = WorkbenchStore()
        workbench.route = .tools
        workbench.setRoute(.skills)

        #expect(workbench.route == .tools)
        #expect(workbench.isCustomProfilesPresented)

        workbench.rightPanelMode = .changes
        workbench.setRoute(.tools)
        #expect(workbench.route == .tools)
        #expect(workbench.rightPanelMode == nil)
    }

    @Test("Coordinator creation intent is consumed exactly once")
    func coordinatorCreationUsesGuidedProfileFlow() {
        let workbench = WorkbenchStore()

        workbench.requestProfileCreation(role: .coordinatorWorker)

        #expect(workbench.isCustomProfilesPresented)
        #expect(workbench.consumeProfileCreationRequest() == .coordinatorWorker)
        #expect(workbench.consumeProfileCreationRequest() == nil)
    }

    @Test("Public shell enums contain only implemented release surfaces")
    func publicShellContainsOnlyImplementedSurfaces() {
        // These exact lists are the release-boundary tripwire: a new case must
        // arrive with a real consumer and an intentional test update.
        #expect(AppRoute.allCases.map(\.rawValue) == ["chat", "tools", "skills"])
        #expect(
            RightPanelMode.allCases.map(\.rawValue)
                == ["activity", "changes", "commit", "workspaceListing"]
        )
        #expect(
            SettingsSection.allCases.map(\.rawValue)
                == ["general", "editorialDesk", "providers", "reasoning", "agents", "shortcuts"]
        )
    }

    @Test("Runtime rejects an incomplete skill command before inference")
    func runtimeRejectsIncompleteSkillCommand() {
        let runtime = ModelRuntimeStore()

        #expect(runtime.resolvedPrompt(for: "/skill") == nil)
        #expect(runtime.resolvedPrompt(for: "plain request") == "plain request")
    }

    @Test("Response coordinator state remains observable through the facade")
    func responseStateForwardsObservation() async {
        let store = ChatStore(
            conversationRepository: ArchitectureConversationRepository()
        )

        await confirmation("Delegation change is observed") { observed in
            withObservationTracking {
                _ = store.isDelegating
            } onChange: {
                observed()
            }
            store.responseCoordinator.delegationChanged(true)
        }

        #expect(store.isDelegating)
    }

    @Test("Profile handoff busy state remains an observable UI projection")
    func profileHandoffBusyStateRemainsObservable() async {
        let store = ChatStore(
            conversationRepository: ArchitectureConversationRepository()
        )

        await confirmation("Busy projection change is observed") { observed in
            withObservationTracking {
                _ = store.busy
            } onChange: {
                observed()
            }
            store.presentationViewModel.setProfileTransitioning(true)
        }

        #expect(store.busy)
        store.presentationViewModel.setProfileTransitioning(false)
        #expect(!store.busy)
    }

    @Test("A delegation opens Activity once and closing preserves its summary")
    func activityInspectorFollowsUserControl() async throws {
        let store = ChatStore(
            conversationRepository: ArchitectureConversationRepository()
        )
        let envelope = try AgentTaskEnvelope(
            taskID: "task-inspector",
            attemptID: "attempt-inspector",
            goal: "Make the requested focused change.",
            acceptanceCriteria: ["The focused behavior is verified."],
            verificationRequest: .test
        )
        let coordinator = AgentActivityAgent(
            modelName: "DeepSeek",
            role: .powerfulCoordinator
        )
        let worker = AgentActivityAgent(
            modelName: "On-device worker",
            role: .codingWorker
        )
        let callbackEnvelope = try AgentTaskEnvelope(
            taskID: "task-inspector-callback",
            attemptID: "attempt-inspector-callback",
            goal: "Open the Activity projection from a runtime callback.",
            acceptanceCriteria: ["The Activity projection is visible."],
            verificationRequest: .none
        )

        store.handleAgentActivityEvent(
            .started(
                envelope: envelope,
                coordinator: coordinator,
                worker: worker,
                startedAt: .now
            )
        )

        #expect(store.rightPanelMode == .activity)
        #expect(store.currentAgentActivity?.goal == envelope.goal)

        let callbackStore = ChatStore(
            conversationRepository: ArchitectureConversationRepository()
        )
        await callbackStore.responseCoordinator.modelSessionEvents.agentActivityChanged(
            .started(
                envelope: callbackEnvelope,
                coordinator: coordinator,
                worker: worker,
                startedAt: .now
            )
        )
        #expect(callbackStore.rightPanelMode == .activity)

        store.closeRightPanel()
        store.handleAgentActivityEvent(
            .phaseChanged(
                taskID: envelope.taskID,
                attemptID: envelope.attemptID,
                phase: .delegating
            )
        )

        // Phase updates remain visible when reopened but respect an explicit
        // dismissal instead of fighting the user's window management.
        #expect(store.rightPanelMode == nil)
        #expect(store.currentAgentActivity?.phase == .delegating)
        store.toggleRightPanel(.activity)
        #expect(store.rightPanelMode == .activity)
    }

    @Test("Delegated activity entry point remains available without an active task")
    func activityInspectorCanOpenItsEmptyState() {
        let store = ChatStore(
            conversationRepository: ArchitectureConversationRepository()
        )

        store.toggleRightPanel(.activity)

        #expect(store.currentAgentActivity == nil)
        #expect(store.rightPanelMode == .activity)
    }

    @Test(
        "Native split panel keeps AppKit constraints stable",
        .disabled("Requires an interactive AppKit window host; run as UI smoke validation")
    )
    func nativeSplitPanelDoesNotEnterAConstraintLoop() async {
        let store = ChatStore(
            conversationRepository: ArchitectureConversationRepository()
        )
        let root = WorkbenchSplitView()
            .environment(store)
            .environment(SettingsStore())
        // Host the hierarchy in an off-screen view. A test-owned NSWindow
        // shares AppKit window state with the SwiftUI runner and can crash
        // during the suite even though the same constraint pass is valid in
        // isolation.
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_229, height: 770)
        hostingView.layoutSubtreeIfNeeded()

        // Reproduce the user transition rather than starting with an already
        // open inspector; the former regression occurred during insertion.
        store.toggleRightPanel(.changes)
        await settleLayout(of: hostingView)
        #expect(store.rightPanelMode == .changes)

        store.closeRightPanel()
        await settleLayout(of: hostingView)
        #expect(store.rightPanelMode == nil)
    }

    @Test("Long delegated tasks keep full detail behind compact Activity copy")
    func longTaskPresentationUsesProgressiveDisclosure() {
        let implementation = String(
            repeating: "Create Sources/TaskForge/TaskManager.swift with exact code.\n",
            count: 12
        )
        let goal = "Create two files and produce them.\n\n\(implementation)"

        let presentation = AgentTaskPresentation(goal: goal)

        #expect(presentation.summary == "Create two files and produce them.")
        #expect(presentation.showsFullTaskDisclosure)
        #expect(presentation.fullText.contains("TaskManager.swift"))
        // Presentation derives a compact label but never replaces the detail
        // available to the inspector or the envelope used by the worker.
        #expect(presentation.fullText == goal)
    }

    @Test("Short delegated tasks remain immediately visible")
    func shortTaskPresentationDoesNotAddDisclosure() {
        let goal = "Run the focused tests and report failures."
        let presentation = AgentTaskPresentation(goal: goal)

        #expect(presentation.summary == goal)
        #expect(presentation.fullText == goal)
        #expect(!presentation.showsFullTaskDisclosure)
    }

    @Test("Structured worker JSON becomes a readable completed result")
    func structuredResultUsesNativeSummaryAndKeepsTechnicalDetails() throws {
        let raw = """
        ```json
        {
          "goal": "Run git status in the workspace",
          "result": {
            "outcome": "completed",
            "technicalSummary": "The working tree is clean on branch main."
          }
        }
        ```
        """
        let result = try AgentTaskResult(
            taskID: "git-status",
            attemptID: "1",
            outcome: .completed,
            technicalSummary: raw
        )

        let presentation = AgentResultPresentation(result: result)

        #expect(presentation.summary == "The working tree is clean on branch main.")
        #expect(presentation.technicalDetails == raw)
    }

    @Test("Provider control tokens become structured tool actions")
    func protocolArtifactResultShowsActionsInsteadOfTokens() throws {
        let raw = """
        <ctrl46>call:default_api:git{operation:<ctrl46>stage<ctrl46>,paths:[<ctrl46>numeri.swift<ctrl46>]}<ctrl46>}<ctrl45><ctrl46>call:default_api:git{operation:<ctrl46>status<ctrl46>}<ctrl46>}<ctrl46>
        """
        let result = try AgentTaskResult(
            taskID: "stage-status",
            attemptID: "1",
            outcome: .completed,
            technicalSummary: raw
        )

        let presentation = AgentResultPresentation(result: result)

        #expect(presentation.summary == "The worker reported 2 tool actions.")
        #expect(
            presentation.actions == [
                AgentResultAction(
                    tool: "git",
                    operation: "stage",
                    detail: "numeri.swift"
                ),
                AgentResultAction(
                    tool: "git",
                    operation: "status",
                    detail: nil
                )
            ]
        )
        #expect(!presentation.summary.contains("<ctrl"))
        #expect(presentation.technicalDetails == raw)
    }

    @Test("Plain worker summaries remain the primary result")
    func plainResultDoesNotAddTechnicalDisclosure() throws {
        let result = try AgentTaskResult(
            taskID: "focused-change",
            attemptID: "1",
            outcome: .completed,
            technicalSummary: "Implemented the focused change."
        )

        let presentation = AgentResultPresentation(result: result)

        #expect(presentation.summary == "Implemented the focused change.")
        #expect(presentation.technicalDetails == nil)
    }

    @Test("Revision conflict offers one fresh read without automatic retry")
    func revisionConflictRecoveryPreparesFreshRead() throws {
        let result = try AgentTaskResult(
            taskID: "edit-counter",
            attemptID: "attempt-old",
            outcome: .failed,
            technicalSummary: "The file changed after it was read.",
            failureReason: .revisionConflict,
            failureDetail: "Counter.swift changed."
        )
        let activity = AgentActivity(
            taskID: result.taskID,
            attemptID: result.attemptID,
            goal: "Update Counter.swift.",
            verificationRequest: .none,
            coordinator: .init(
                modelName: "DeepSeek",
                role: .powerfulCoordinator
            ),
            worker: .init(
                modelName: "Apple PCC",
                role: .codingWorker
            ),
            phase: .failed,
            lastOperationalPhase: .workerRunning,
            activeTool: nil,
            startedAt: .now,
            completedAt: .now,
            finalResult: result
        )

        let recovery = try #require(
            AgentRecoveryPresentation(
                result: result,
                reviewableReceiptID: nil
            )
        )
        let draft = try #require(
            recovery.draft(
                for: activity,
                newAttemptID: "attempt-fresh"
            )
        )

        #expect(recovery.action == .prepareReread)
        #expect(recovery.title == "Prepare New Reading")
        #expect(draft.contains("New attempt ID: attempt-fresh"))
        #expect(draft.contains("Re-read the affected file"))
        #expect(draft.contains("Do not reuse the previous revision hash"))
    }

    @Test("Verification failure prefers the available immutable receipt")
    func verificationRecoveryOpensOneReviewSurface() throws {
        let result = try AgentTaskResult(
            taskID: "verify-change",
            attemptID: "attempt-1",
            outcome: .failed,
            technicalSummary: "The build failed.",
            receiptIDs: ["diff-receipt"],
            verification: .init(
                status: .failed,
                detail: "XCODE BUILD FAILED"
            ),
            failureReason: .verificationFailed
        )

        let recovery = try #require(
            AgentRecoveryPresentation(
                result: result,
                reviewableReceiptID: "diff-receipt"
            )
        )

        #expect(
            recovery.action == .reviewChanges(receiptID: "diff-receipt")
        )
        #expect(!recovery.action.requiresComposer)
    }

    @Test("Scope failure stays with the coordinator before redelegation")
    func scopeRecoveryUsesCoordinator() throws {
        let result = try AgentTaskResult(
            taskID: "scope-change",
            attemptID: "attempt-1",
            outcome: .failed,
            technicalSummary: "The requested path was outside the task scope.",
            failureReason: .pathOutsideScope
        )

        let recovery = try #require(
            AgentRecoveryPresentation(
                result: result,
                reviewableReceiptID: nil
            )
        )

        #expect(recovery.action == .runCoordinator)
        #expect(recovery.title == "Continue in Coordinator")
    }

    private func settleLayout(of view: NSView) async {
        // Two observation turns let SwiftUI insert/remove the split panel
        // before AppKit performs the explicit constraint pass.
        await Task.yield()
        await Task.yield()
        view.layoutSubtreeIfNeeded()
    }
}

/// Keeps façade tests isolated from the user's persisted conversation catalog.
private struct ArchitectureConversationRepository: ConversationRepository {
    func save(_ snapshot: ConversationSnapshot) throws {}
    func load(id: String) throws -> ConversationSnapshot? { nil }
    func list() throws -> [ConversationSnapshot] { [] }
    func delete(id: String) throws {}
}
