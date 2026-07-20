import SwiftUI
import Testing
@testable import TurboCode

@Suite("Message timeline scroll state")
struct MessageTimelineScrollTests {
    @Test("Streaming content growth remains pinned while following")
    func contentGrowthRequestsBottomAdjustment() {
        var state = TimelineScrollFollowState()

        let shouldScroll = state.updateGeometry(
            from: snapshot(contentHeight: 1_000, remaining: 0),
            to: snapshot(contentHeight: 1_120, remaining: 120)
        )

        #expect(shouldScroll)
        #expect(state.followsLatestMessage)
    }

    @Test("User scrolling away pauses live following")
    func userScrollAwayPausesFollowing() {
        var state = TimelineScrollFollowState()
        state.updateScrollPhase(.interacting)

        let shouldScroll = state.updateGeometry(
            from: snapshot(contentHeight: 1_000, remaining: 0),
            to: snapshot(contentHeight: 1_000, remaining: 240)
        )
        state.updateScrollPhase(.idle)

        #expect(!shouldScroll)
        #expect(!state.followsLatestMessage)
        #expect(!state.isUserScrolling)
    }

    @Test("Returning to the bottom resumes live following")
    func returningToBottomResumesFollowing() {
        var state = TimelineScrollFollowState()
        state.updateScrollPhase(.interacting)
        _ = state.updateGeometry(
            from: snapshot(contentHeight: 1_000, remaining: 200),
            to: snapshot(contentHeight: 1_000, remaining: 0)
        )
        state.updateScrollPhase(.idle)

        #expect(state.followsLatestMessage)
        #expect(state.isNearBottom)
    }

    @Test("Programmatic animation preserves user intent")
    func programmaticAnimationDoesNotPauseFollowing() {
        var state = TimelineScrollFollowState()

        state.updateScrollPhase(.animating)

        #expect(state.followsLatestMessage)
        #expect(!state.isUserScrolling)
    }

    private func snapshot(contentHeight: CGFloat, remaining: CGFloat) -> TimelineScrollSnapshot {
        TimelineScrollSnapshot(
            contentHeight: contentHeight,
            visibleMaxY: contentHeight - remaining
        )
    }
}
