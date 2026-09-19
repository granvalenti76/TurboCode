import Foundation
import Testing
import FoundationModels
@testable import TurboCode

@Suite("Dynamic tool routing")
struct DynamicRoutingTests {
    @Test("Dynamic sessions expose exactly their package, including zero tools",
          arguments: [Optional<DynamicToolPackage>.none, .conversation, .git, .coding])
    @MainActor
    func sessionToolDefinitionsMatchPackage(_ package: DynamicToolPackage?) throws {
        var tuning = AgentTuningConfig.default
        // A global integration must not escape the package boundary.
        tuning.experimental.safariMCPEnabled = true
        tuning.experimental.thirdPartyPluginsEnabled = true
        let session = ModelSessionFactory.makeSession(
            configuration: ModelSessionConfiguration(
                backend: .llamaServer,
                activeRemoteModel: .fallbackLlama,
                delegateRemoteModel: .fallbackLlama,
                orchestratorMode: .standalone,
                workspaceRoot: "/tmp/workspace",
                agentTuning: tuning,
                availableSkills: [],
                documentationStore: .live,
                activeDynamicProfile: nil,
                dynamicRoutingEnabled: true,
                dynamicRoutingToolIDs: package?.toolIDs,
                reasoningEffort: nil,
                delegateReasoningEffort: nil,
                activeTemperature: nil,
                delegateTemperature: nil,
                delegateToolIDs: nil,
                dropsCompletedToolCalls: false,
                workspaceInstructions: nil
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
        let names = instructions.toolDefinitions.map(\.name)
        // This fixture has no Markdown skills; workspace tools stay available.
        let expected = (package?.toolIDs ?? []).subtracting([.loadSkill])
        #expect(Set(names) == Set(expected.map(\.runtimeName)))
        #expect(names.count == Set(names).count)
    }

    @Test("The broad implementation package requires edit and verify intent")
    func broadPackageRequiresCombinedWork() {
        let allowed = Set(ToolCapabilityID.allCases)
        #expect(!DynamicToolPackageResolver.candidates(allowedToolIDs: allowed, prompt: "mostra il diff git").contains(.implementation))
        #expect(DynamicToolPackageResolver.candidates(allowedToolIDs: allowed, prompt: "implementa la feature e verifica con i test").contains(.implementation))
    }
    @Test("Candidate packages stay inside the profile capability boundary")
    func candidatePackagesRespectAllowlist() {
        let allowed: Set<ToolCapabilityID> = [
            .listWorkspace,
            .fileSystem,
            .readFile,
            .searchWorkspace,
            .git
        ]

        let candidates = DynamicToolPackageResolver.candidates(
            allowedToolIDs: allowed
        )

        #expect(candidates.contains(.conversation))
        #expect(candidates.contains(.exploration))
        #expect(candidates.contains(.git))
        #expect(!candidates.contains(.build))
        #expect(
            DynamicToolPackageResolver.effectiveToolIDs(
                for: .implementation,
                allowedToolIDs: allowed
            ) == allowed
        )
    }

    @Test("Missing AnchorSignal assets use a bounded lexical fallback")
    func missingAssetsUseFallback() async {
        let classifier = AnchorSignalClassifier(
            configuration: AnchorSignalConfiguration(
                modelURL: URL(fileURLWithPath: "/tmp/missing-anchor-model.aimodel"),
                tokenizerURL: URL(fileURLWithPath: "/tmp/missing-anchor-tokenizer.json"),
                maximumTokenCount: 64
            )
        )

        let decision = await classifier.classify(
            prompt: "controlla lo stato git e mostrami il diff",
            allowedToolIDs: [
                .listWorkspace,
                .readFile,
                .searchWorkspace,
                .git
            ]
        )

        #expect(decision.source == .fallback)
        #expect(decision.package == .git)
        #expect(
            decision.toolIDs == [
                .listWorkspace,
                .readFile,
                .searchWorkspace,
                .git
            ]
        )
    }
}
