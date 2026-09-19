import Foundation
import Testing
import FoundationModels
@testable import TurboCode

@Suite("Dynamic tool routing")
struct DynamicRoutingTests {
    // Opt in on a machine with the external alpha encoder. Requiring .model
    // prevents lexical fallback from masquerading as multilingual validation.
    @Test("Real AnchorSignal distinguishes bilingual file edits from chat rewrites",
          .enabled(if: ProcessInfo.processInfo.environment["TURBOCODE_EVALUATE_ANCHORSIGNAL"] == "1"))
    func multilingualSemanticRouting() async {
        let classifier = AnchorSignalClassifier()
        let cases: [(String, DynamicToolPackage)] = [
            ("Riscrivi il file README.md in inglese.", .coding),
            ("Rewrite the README.md file in English.", .coding),
            ("Vorrei che il testo dentro CONTRIBUTING.md fosse tutto in inglese, puoi occupartene?", .coding),
            ("Please make the contents of CONTRIBUTING.md English throughout.", .coding),
            ("Traduci in inglese i commenti di App.swift e salva le modifiche.", .coding),
            ("Translate the comments in App.swift into English and save your changes.", .coding),
            ("Riscrivi questo paragrafo in inglese: la nostra app aiuta a programmare.", .conversation),
            ("Rewrite this paragraph in English: la nostra app aiuta a programmare.", .conversation),
            ("Traduci questa frase in inglese: il gatto dorme sul divano.", .conversation),
            ("Translate this sentence into English: il gatto dorme sul divano.", .conversation),
            ("Spiegami come funziona un actor Swift.", .conversation),
            ("Explain how a Swift actor works.", .conversation),
            ("Leggi README.md e dimmi di cosa parla il progetto.", .exploration),
            ("Read README.md and tell me what the project does.", .exploration),
            ("e ora esplora i .md", .exploration),
            ("Esplora tutti i file Markdown nel workspace.", .exploration),
            ("Now explore the .md files.", .exploration),
            ("Browse all Markdown files in the workspace.", .exploration),
            ("Mostrami i branch e lo stato git.", .git),
            ("Show me the branches and git status.", .git),
            ("Esegui la suite di test esistente.", .build),
            ("Run the existing test suite.", .build),
            ("Correggi il bug e compila il progetto.", .implementation),
            ("Fix the bug and build the project.", .implementation),
            ("Ciao, come stai?", .conversation),
            ("Hello, how are you?", .conversation),
            ("salve", .conversation),
            ("Buongiorno!", .conversation),
            ("Hey there", .conversation),
            ("Aiutami a ragionare su un'idea per una nuova app.", .conversation),
            ("Help me brainstorm an idea for a new app.", .conversation),
            ("boh, non saprei", .conversation),
            ("non so ancora cosa fare", .conversation),
            ("whatever, I am not sure yet", .conversation),
            ("asdf qwerty", .conversation),
            ("Il documento docs/setup.md è in italiano: rendilo leggibile ai colleghi inglesi e salvalo.", .coding),
            ("The docs/setup.md document is in Italian: make it readable for English colleagues and save it.", .coding)
        ]
        // Reuse one classifier to exercise its anchor cache as well as cold load.
        for (prompt, expected) in cases {
            let decision = await classifier.classify(
                prompt: prompt,
                allowedToolIDs: Set(ToolCapabilityID.allCases)
            )
            #expect(decision.source == .model, "\(prompt): \(decision.fallbackReason ?? "missing model result")")
            #expect(decision.package == expected,
                    "\(prompt): selected \(decision.package), expected \(expected), score \(decision.topScore), margin \(decision.margin)")
        }
    }

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
