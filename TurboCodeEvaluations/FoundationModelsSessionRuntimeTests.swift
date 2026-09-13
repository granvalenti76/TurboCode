import Foundation
import FoundationModels
import FoundationModelsUtilities
import Testing
@testable import TurboCode

@MainActor
@Suite("Foundation Models session runtime ownership")
struct FoundationModelsSessionRuntimeTests {
    @Test("Runtime scopes the reasoning relay to Llama")
    func reasoningRelayIsProviderScoped() async throws {
        let runtime = FoundationModelsSessionRuntime(
            backend: .llamaServer
        ) { _ in
            SystemLanguageModel.default
        }

        let llamaRelay = await runtime.resources(for: .llamaServer).reasoningRelay
        #expect(llamaRelay != nil)
        #expect(
            await runtime.resources(for: .foundationApple).reasoningRelay == nil
        )
    }

    @Test("Rebuild replaces the session and relay as one runtime unit")
    func rebuildReplacesProviderObjectsTogether() async throws {
        let runtime = FoundationModelsSessionRuntime(
            backend: .llamaServer,
            modelBuilder: { _ in SystemLanguageModel.default }
        )
        let firstResources = await runtime.resources(for: .llamaServer)
        let firstSession = firstResources.session
        let firstRelay = try #require(
            firstResources.reasoningRelay
        )
        await runtime.rebuild(
            configuration: Self.onDeviceConfiguration(),
            canonicalHistory: [],
            projection: .empty,
            events: Self.noopEvents
        )

        let secondResources = await runtime.resources(for: .llamaServer)
        let secondRelay = try #require(secondResources.reasoningRelay)
        #expect(secondResources.session !== firstSession)
        #expect(secondRelay !== firstRelay)
    }

    @Test("Context projection preserves canonical tool history")
    func projectionKeepsCanonicalHistory() async throws {
        let runtime = FoundationModelsSessionRuntime(
            backend: .llamaServer,
            modelBuilder: { _ in SystemLanguageModel.default }
        )
        let text: (String) -> Transcript.Segment = {
            .text(Transcript.TextSegment(content: $0))
        }
        let call = Transcript.ToolCall(
            id: "call-context",
            toolName: "read_file",
            arguments: GeneratedContent(properties: ["path": "README.md"])
        )
        let canonical: [Transcript.Entry] = [
            .prompt(Transcript.Prompt(segments: [text("Inspect")])),
            .toolCalls(Transcript.ToolCalls([call])),
            .toolOutput(Transcript.ToolOutput(
                id: call.id,
                toolName: call.toolName,
                segments: [text("Contents")]
            )),
            .response(Transcript.Response(assetIDs: [], segments: [text("Done")]))
        ]

        await runtime.rebuild(
            configuration: Self.onDeviceConfiguration(),
            canonicalHistory: canonical,
            projection: TranscriptContextProjection(
                excludedToolCallIDs: [call.id]
            ),
            events: Self.noopEvents
        )

        let persisted = await runtime.canonicalTranscript()
        let materialized = await runtime.transcript
        #expect(persisted.contains { if case .toolCalls = $0 { true } else { false } })
        #expect(materialized.contains { if case .toolCalls = $0 { true } else { false } } == false)
        #expect(materialized.contains { if case .toolOutput = $0 { true } else { false } } == false)
    }

    @Test("Rematerialized instructions do not duplicate canonical history")
    func rematerializedInstructionsDoNotDuplicateHistory() {
        let earlierPrompt = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [Self.text("Earlier request")])
        )
        let earlierResponse = Transcript.Entry.response(
            Transcript.Response(
                assetIDs: [],
                segments: [Self.text("Earlier response")]
            )
        )
        let nextPrompt = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [Self.text("Next request")])
        )
        let previous = [
            Self.instructions("Previous instructions"),
            earlierPrompt,
            earlierResponse
        ]
        let current = [
            Self.instructions("Rematerialized instructions"),
            earlierPrompt,
            earlierResponse,
            nextPrompt
        ]

        let delta = FoundationModelsTranscriptDelta.newEntries(
            previous: previous,
            current: current
        )

        #expect(delta == [nextPrompt])
        #expect(!delta.contains { if case .instructions = $0 { true } else { false } })
    }

    @Test("Transcript pruning still appends only genuinely new entries")
    func prunedTranscriptAppendsOnlyNewEntries() {
        let prompt = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [Self.text("Inspect")])
        )
        let call = Transcript.ToolCall(
            id: "call-pruned-history",
            toolName: "read_file",
            arguments: GeneratedContent(properties: ["path": "README.md"])
        )
        let toolCalls = Transcript.Entry.toolCalls(Transcript.ToolCalls([call]))
        let toolOutput = Transcript.Entry.toolOutput(
            Transcript.ToolOutput(
                id: call.id,
                toolName: call.toolName,
                segments: [Self.text("Contents")]
            )
        )
        let response = Transcript.Entry.response(
            Transcript.Response(assetIDs: [], segments: [Self.text("Done")])
        )
        let nextPrompt = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [Self.text("Continue")])
        )

        let delta = FoundationModelsTranscriptDelta.newEntries(
            previous: [
                Self.instructions("Previous instructions"),
                prompt,
                toolCalls,
                toolOutput,
                response
            ],
            current: [
                Self.instructions("Rematerialized instructions"),
                prompt,
                response,
                nextPrompt
            ]
        )

        #expect(delta == [nextPrompt])
    }

    private static func text(_ value: String) -> Transcript.Segment {
        .text(Transcript.TextSegment(content: value))
    }

    private static func instructions(_ value: String) -> Transcript.Entry {
        .instructions(
            Transcript.Instructions(
                segments: [text(value)],
                toolDefinitions: []
            )
        )
    }

    private static var noopEvents: ModelSessionEvents {
        ModelSessionEvents(
            toolStarted: { _, _, _ in },
            toolFinished: { _, _, _, _ in },
            delegationChanged: { _ in }
        )
    }

    private static func onDeviceConfiguration() -> ModelSessionConfiguration {
        ModelSessionConfiguration(
            backend: .foundationApple,
            activeRemoteModel: nil,
            delegateRemoteModel: .fallbackLlama,
            orchestratorMode: .standalone,
            workspaceRoot: FileManager.default.temporaryDirectory.path,
            agentTuning: .default,
            availableSkills: [],
            documentationStore: .live,
            activeDynamicProfile: nil,
            reasoningEffort: nil,
            delegateReasoningEffort: nil,
            activeTemperature: nil,
            delegateTemperature: nil,
            delegateToolIDs: nil,
            dropsCompletedToolCalls: true,
            workspaceInstructions: nil
        )
    }
}
