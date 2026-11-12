import Foundation
import Testing
@testable import TurboCode

@Suite("Turn status prompts")
struct TurnStatusPromptTests {
    @Test("Only a short single-line message is offered to the classifier")
    func candidateFilter() {
        #expect(TurnStatusPrompts.isStatusCandidate("a che punto sei?"))
        #expect(TurnStatusPrompts.isStatusCandidate("  où en es-tu ?  "))
        #expect(!TurnStatusPrompts.isStatusCandidate(""))
        #expect(!TurnStatusPrompts.isStatusCandidate("status?\nalso use pandas"))
        #expect(
            !TurnStatusPrompts.isStatusCandidate(
                String(repeating: "x", count: TurnStatusPrompts.candidateCharacterLimit + 1)
            )
        )
    }

    @Test("Anything but a clear STATUS verdict is treated as an instruction")
    func classifierOutputParsing() {
        #expect(TurnStatusPrompts.kind(fromClassifierOutput: " status\n") == .statusQuestion)
        #expect(TurnStatusPrompts.kind(fromClassifierOutput: "STATUS.") == .statusQuestion)
        #expect(TurnStatusPrompts.kind(fromClassifierOutput: "INSTRUCTION") == .instruction)
        #expect(TurnStatusPrompts.kind(fromClassifierOutput: "STATUS or INSTRUCTION") == .instruction)
        #expect(TurnStatusPrompts.kind(fromClassifierOutput: "I think it is a status") == .instruction)
        #expect(TurnStatusPrompts.kind(fromClassifierOutput: "") == .instruction)
    }

    @Test("The summary prompt keeps the newest work and stays within budget")
    func summaryPromptIsBounded() {
        let calls = (1...10).map { index in
            LiveToolCall(
                id: "\(index)",
                callID: "call_\(index)",
                round: index,
                name: "tool_\(index)",
                arguments: String(repeating: "a", count: 5_000),
                fragmentCount: 1,
                phase: .written
            )
        }
        let prompt = TurnStatusPrompts.summary(
            question: "où en es-tu ?",
            context: TurnStatusContext(
                lastUserMessage: "GOAL" + String(repeating: "u", count: 20_000),
                reasoning: String(repeating: "r", count: 20_000) + "NEWEST_REASONING",
                assistantText: String(repeating: "t", count: 20_000) + "NEWEST_TEXT",
                toolCalls: calls
            )
        )

        #expect(prompt.contains("où en es-tu ?"))
        #expect(prompt.contains("GOAL"))
        #expect(prompt.contains("NEWEST_REASONING"))
        #expect(prompt.contains("NEWEST_TEXT"))
        #expect(prompt.contains("tool_10") && prompt.contains("tool_5"))
        #expect(!prompt.contains("tool_4 "))
        // About 2,500 tokens at four characters per token, with headroom.
        #expect(prompt.count < 9_000)
    }

    @Test("Empty sections are left out of the summary prompt")
    func summaryPromptOmitsEmptySections() {
        let prompt = TurnStatusPrompts.summary(
            question: "status?",
            context: TurnStatusContext(
                lastUserMessage: "",
                reasoning: "",
                assistantText: "",
                toolCalls: []
            )
        )
        #expect(!prompt.contains("tool calls"))
        #expect(!prompt.contains("latest reasoning"))
    }
}

@MainActor
@Suite("Turn status routing")
struct TurnStatusStoreTests {
    private static let context = TurnStatusContext(
        lastUserMessage: "Build the report",
        reasoning: "",
        assistantText: "",
        toolCalls: []
    )

    private func store(
        _ assistant: StubTurnStatusAssistant,
        running: Bool = true,
        timeout: Duration = .seconds(2)
    ) -> TurnStatusStore {
        TurnStatusStore(
            assistant: assistant,
            classificationTimeout: timeout,
            context: { running ? Self.context : nil }
        )
    }

    @Test("A progress question is answered on the side and not queued")
    func statusQuestionIsAnswered() async {
        let assistant = StubTurnStatusAssistant(verdict: .statusQuestion, answer: "Half way.")
        let store = store(assistant)

        #expect(await store.intercept("a che punto sei?"))
        await waitUntil { store.card?.phase == .done }

        #expect(store.card?.question == "a che punto sei?")
        #expect(store.card?.answer == "Half way.")
        #expect(assistant.summaryPrompts.first?.contains("Build the report") == true)
    }

    @Test("An instruction, a long message and an idle turn all go to steering")
    func everythingElseIsLeftToSteering() async {
        let instruction = store(StubTurnStatusAssistant(verdict: .instruction))
        #expect(await instruction.intercept("use pandas") == false)

        let longAssistant = StubTurnStatusAssistant(verdict: .statusQuestion)
        let long = store(longAssistant)
        #expect(await long.intercept(String(repeating: "x", count: 400)) == false)
        #expect(longAssistant.classifiedTexts.isEmpty)

        let idleAssistant = StubTurnStatusAssistant(verdict: .statusQuestion)
        let idle = store(idleAssistant, running: false)
        #expect(await idle.intercept("status?") == false)
        #expect(idleAssistant.classifiedTexts.isEmpty)

        let unavailable = StubTurnStatusAssistant(verdict: .statusQuestion, isAvailable: false)
        #expect(await store(unavailable).intercept("status?") == false)

        #expect(instruction.card == nil && long.card == nil && idle.card == nil)
    }

    @Test("A classifier that is too slow or undecided yields steering")
    func slowOrUndecidedClassifierYieldsSteering() async {
        let slow = StubTurnStatusAssistant(verdict: .statusQuestion, delay: .seconds(5))
        #expect(await store(slow, timeout: .milliseconds(50)).intercept("status?") == false)

        let undecided = StubTurnStatusAssistant(verdict: nil)
        #expect(await store(undecided).intercept("status?") == false)
    }

    @Test("The question can be taken back to send it to the working model")
    func questionCanBeTakenBack() async {
        let store = store(StubTurnStatusAssistant(verdict: .statusQuestion, answer: "Half way."))
        _ = await store.intercept("status?")

        #expect(store.takeQuestion() == "status?")
        #expect(store.card == nil)
        #expect(store.takeQuestion() == nil)
    }

    @Test("A failed summary is reported on the card")
    func failedSummaryIsReported() async {
        let store = store(StubTurnStatusAssistant(verdict: .statusQuestion, answer: nil))
        _ = await store.intercept("status?")
        await waitUntil { store.card?.phase == .failed }
        #expect(store.card?.phase == .failed)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class StubTurnStatusAssistant: TurnStatusAssisting {
    struct Failure: Error {}

    let isAvailable: Bool
    private let verdict: SteeringMessageKind?
    private let answer: String?
    private let delay: Duration?
    private(set) var classifiedTexts: [String] = []
    private(set) var summaryPrompts: [String] = []

    init(
        verdict: SteeringMessageKind?,
        answer: String? = "ok",
        delay: Duration? = nil,
        isAvailable: Bool = true
    ) {
        self.verdict = verdict
        self.answer = answer
        self.delay = delay
        self.isAvailable = isAvailable
    }

    func classify(_ text: String) async -> SteeringMessageKind? {
        classifiedTexts.append(text)
        if let delay {
            try? await Task.sleep(for: delay)
        }
        return verdict
    }

    func summarize(
        prompt: String,
        onUpdate: @MainActor @Sendable (String) -> Void
    ) async throws {
        summaryPrompts.append(prompt)
        guard let answer else { throw Failure() }
        onUpdate(answer)
    }
}
