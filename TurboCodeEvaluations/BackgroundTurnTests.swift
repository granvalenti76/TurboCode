import Foundation
import Testing
@testable import TurboCode

/// A running turn survives navigation to other chats, unseen endings are
/// remembered, and reply notifications carry a clean, short excerpt.
@Suite("Background turns and reply notifications")
struct BackgroundTurnTests {
    private static func snapshot(
        thread: String?,
        running: Bool,
        outcome: TurnOutcome? = nil
    ) -> RuntimeSnapshot {
        RuntimeSnapshot(
            activeThreadID: thread,
            backend: .foundationApple,
            turn: TurnState(id: TurnID(), startedAt: .now, outcome: outcome),
            hasActiveOperation: running
        )
    }

    @Test("Opening another chat while a turn runs previews it instead of switching")
    func openDecisionKeepsRunningTurn() {
        #expect(BackgroundTurnPolicy.openDecision(target: "a", runningThreadID: nil) == .open)
        #expect(BackgroundTurnPolicy.openDecision(target: "a", runningThreadID: "a") == .returnToRunning)
        #expect(BackgroundTurnPolicy.openDecision(target: "b", runningThreadID: "a") == .preview)
    }

    @Test("Only success and failure are worth reporting")
    func cancelledTurnsAreNotNews() {
        #expect(BackgroundTurnPolicy.isWorthReporting(.succeeded))
        #expect(BackgroundTurnPolicy.isWorthReporting(.failed(TurnFailure(code: "x", message: "y"))))
        #expect(!BackgroundTurnPolicy.isWorthReporting(.cancelled(reason: nil)))
        #expect(!BackgroundTurnPolicy.isWorthReporting(nil))
    }

    @Test("A turn finishing in the background marks the chat unread and reports it once")
    @MainActor
    func backgroundFinishIsReported() {
        let store = BackgroundTurnStore()
        var reported: [String] = []
        store.isAppActive = { false }
        store.turnFinishedInBackground = { id, _ in reported.append(id) }

        store.runtimeSnapshotChanged(Self.snapshot(thread: "a", running: true))
        #expect(store.runningThreadID == "a")
        store.runtimeSnapshotChanged(Self.snapshot(thread: "a", running: false, outcome: .succeeded))
        store.runtimeSnapshotChanged(Self.snapshot(thread: "a", running: false, outcome: .succeeded))

        #expect(store.runningThreadID == nil)
        #expect(store.unreadThreadIDs == ["a"])
        #expect(reported == ["a"])
        store.markSeen("a")
        #expect(store.unreadThreadIDs.isEmpty)
    }

    @Test("A turn the user watched end is neither unread nor notified")
    @MainActor
    func watchedFinishIsSilent() {
        let store = BackgroundTurnStore()
        var reported = 0
        store.isAppActive = { true }
        store.turnFinishedInBackground = { _, _ in reported += 1 }

        store.runtimeSnapshotChanged(Self.snapshot(thread: "a", running: true))
        store.runtimeSnapshotChanged(Self.snapshot(thread: "a", running: false, outcome: .succeeded))
        #expect(store.unreadThreadIDs.isEmpty)
        #expect(reported == 0)
    }

    @Test("Reading another chat inside TurboCode marks unread but posts no notification")
    @MainActor
    func previewFinishIsUnreadButSilent() {
        let store = BackgroundTurnStore()
        var reported = 0
        store.isAppActive = { true }
        store.turnFinishedInBackground = { _, _ in reported += 1 }

        store.runtimeSnapshotChanged(Self.snapshot(thread: "a", running: true))
        store.beginPreview(threadID: "b", blocks: [])
        store.runtimeSnapshotChanged(Self.snapshot(thread: "a", running: false, outcome: .succeeded))
        #expect(store.unreadThreadIDs == ["a"])
        #expect(reported == 0)
        // The preview stays until the user leaves it.
        #expect(store.previewThreadID == "b")
    }

    @Test("The excerpt drops Markdown and code, and is cut at a word")
    func excerptIsCleanAndShort() {
        let reply = """
        ## Done

        I updated **three files** and [the docs](https://example.com).
        ```swift
        let secret = 1
        ```
        - Next: run the `tests`.
        """
        let excerpt = ReplyNotificationContent.excerpt(from: reply)
        #expect(excerpt == "Done I updated three files and the docs. Next: run the tests.")

        let long = String(repeating: "word ", count: 80)
        let cut = ReplyNotificationContent.excerpt(from: long)
        #expect(cut.count <= ReplyNotificationContent.excerptLimit + 1)
        #expect(cut.hasSuffix("word…"))
    }

    @Test("Notification text follows the outcome and the excerpt setting")
    func notificationContentRespectsSettings() {
        let withExcerpt = ReplyNotificationContent(
            chatTitle: "Chat", outcome: .succeeded, reply: "All good.", includeExcerpt: true
        )
        #expect(withExcerpt == ReplyNotificationContent(
            chatTitle: "Chat", outcome: .succeeded, reply: "All good.", includeExcerpt: true
        ))
        #expect(withExcerpt.body == "All good.")
        #expect(ReplyNotificationContent(
            chatTitle: "Chat", outcome: .succeeded, reply: "All good.", includeExcerpt: false
        ).body == "The reply is ready.")
        #expect(ReplyNotificationContent(
            chatTitle: "Chat", outcome: .failed(TurnFailure(code: "x", message: "y")),
            reply: "partial", includeExcerpt: true
        ).body == "The reply stopped with an error.")
    }
}
