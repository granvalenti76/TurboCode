import Foundation
import Observation

/// Keeps a running turn alive while the user looks at other chats, and
/// remembers which chats finished while nobody was watching.
///
/// TurboCode runs one model session at a time, and installing another chat
/// cancels the running turn (`RuntimeTransitionBarrier`). So while a turn is
/// running, opening another chat does not install it: it is shown read-only
/// from disk (`previewThreadID`, `previewBlocks`) and the live runtime,
/// timeline and conversation identity stay with the running chat. Returning
/// to the running chat only closes the preview.
@MainActor
@Observable
final class BackgroundTurnStore {
    /// The chat whose turn is running, or nil when idle.
    private(set) var runningThreadID: String?
    /// The chat shown read-only while another chat's turn runs.
    private(set) var previewThreadID: String?
    private(set) var previewBlocks: [ChatBlock] = []
    /// Chats whose turn finished while the user was elsewhere.
    private(set) var unreadThreadIDs: Set<String> = []

    /// Called when a turn finishes while TurboCode is in the background;
    /// wired to the notification service. Reading another chat inside
    /// TurboCode only leaves the unread dot: the user is already in the app.
    @ObservationIgnored
    var turnFinishedInBackground: ((_ threadID: String, _ outcome: TurnOutcome?) -> Void)?

    /// Reports whether the app is frontmost; injectable for tests.
    @ObservationIgnored
    var isAppActive: () -> Bool = { true }

    /// Follows the runtime. A turn has finished when the chat that owned the
    /// running operation no longer does.
    func runtimeSnapshotChanged(_ snapshot: RuntimeSnapshot) {
        let running = BackgroundTurnPolicy.runningThreadID(in: snapshot)
        guard running != runningThreadID else { return }
        let finished = runningThreadID
        runningThreadID = running
        if let finished, running != finished {
            turnFinished(threadID: finished, outcome: snapshot.turn?.outcome)
        }
    }

    func beginPreview(threadID: String, blocks: [ChatBlock]) {
        previewThreadID = threadID
        previewBlocks = blocks
        unreadThreadIDs.remove(threadID)
    }

    func endPreview() {
        previewThreadID = nil
        previewBlocks = []
    }

    /// The user is looking at `threadID` in the live view.
    func markSeen(_ threadID: String) {
        unreadThreadIDs.remove(threadID)
    }

    private func turnFinished(threadID: String, outcome: TurnOutcome?) {
        let appActive = isAppActive()
        let watched = BackgroundTurnPolicy.isWatched(
            appActive: appActive,
            previewing: previewThreadID != nil
        )
        guard !watched, BackgroundTurnPolicy.isWorthReporting(outcome) else { return }
        unreadThreadIDs.insert(threadID)
        if BackgroundTurnPolicy.shouldNotify(appActive: appActive) {
            turnFinishedInBackground?(threadID, outcome)
        }
    }
}

/// Pure decisions behind `BackgroundTurnStore`, kept apart for tests.
nonisolated enum BackgroundTurnPolicy {
    enum OpenDecision: Equatable {
        /// Install the chat as usual (no turn is running).
        case open
        /// Show it read-only; a turn of another chat is running.
        case preview
        /// The running chat itself: close any preview, change nothing else.
        case returnToRunning
    }

    static func runningThreadID(in snapshot: RuntimeSnapshot) -> String? {
        snapshot.hasActiveOperation ? snapshot.activeThreadID : nil
    }

    static func openDecision(target: String, runningThreadID: String?) -> OpenDecision {
        guard let runningThreadID else { return .open }
        return target == runningThreadID ? .returnToRunning : .preview
    }

    /// The user saw the turn end only when TurboCode was frontmost and the
    /// running chat itself was on screen.
    static func isWatched(appActive: Bool, previewing: Bool) -> Bool {
        appActive && !previewing
    }

    /// A system notification is for when the user left TurboCode. While they
    /// use it, even on another chat, the sidebar dot is enough.
    static func shouldNotify(appActive: Bool) -> Bool {
        !appActive
    }

    /// A turn the user stopped, or one cancelled by a context change, is not
    /// news. Success and failure are.
    static func isWorthReporting(_ outcome: TurnOutcome?) -> Bool {
        switch outcome {
        case .succeeded, .failed: true
        case .cancelled, nil: false
        }
    }
}
