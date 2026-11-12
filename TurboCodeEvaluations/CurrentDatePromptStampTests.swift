import Foundation
import Testing
@testable import TurboCode

@Suite("Current date prompt stamp")
struct CurrentDatePromptStampTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }

    private func date(_ day: Int, hour: Int) -> Date {
        calendar.date(
            from: DateComponents(year: 2026, month: 11, day: day, hour: hour)
        )!
    }

    @Test("The first message of a conversation states the date once per day")
    func firstMessageOfTheDayIsStamped() {
        var stamp = CurrentDatePromptStamp()
        let morning = date(11, hour: 9)

        let first = stamp.stamped("hello", conversationID: "a", now: morning, calendar: calendar)
        let second = stamp.stamped(
            "again",
            conversationID: "a",
            now: date(11, hour: 23),
            calendar: calendar
        )

        #expect(
            first == "hello\n\n[Current date: Wednesday, 11 November 2026 "
                + "(Europe/Rome). Treat this as today, not your training cutoff.]"
        )
        #expect(second == "again")
    }

    @Test("A new day or another conversation states the date again")
    func newDayOrConversationIsStamped() {
        var stamp = CurrentDatePromptStamp()
        _ = stamp.stamped("one", conversationID: "a", now: date(11, hour: 23), calendar: calendar)

        let nextDay = stamp.stamped("two", conversationID: "a", now: date(12, hour: 0), calendar: calendar)
        let other = stamp.stamped("three", conversationID: "b", now: date(12, hour: 0), calendar: calendar)

        #expect(nextDay.contains("Thursday, 12 November 2026"))
        #expect(other.contains("Thursday, 12 November 2026"))
    }

    @Test("A withdrawn stamp is stated again by the next message")
    func withdrawnStampIsStatedAgain() {
        var stamp = CurrentDatePromptStamp()
        let morning = date(11, hour: 9)
        _ = stamp.stamped("refused", conversationID: "a", now: morning, calendar: calendar)
        _ = stamp.stamped("kept", conversationID: "b", now: morning, calendar: calendar)

        stamp.withdraw(conversationID: "a")

        let retry = stamp.stamped("retry", conversationID: "a", now: morning, calendar: calendar)
        let other = stamp.stamped("next", conversationID: "b", now: morning, calendar: calendar)
        #expect(retry.contains("Wednesday, 11 November 2026"))
        #expect(other == "next")
    }

    @Test("A turn without a conversation is left untouched")
    func missingConversationIsNotStamped() {
        var stamp = CurrentDatePromptStamp()
        #expect(stamp.stamped("hello", conversationID: nil) == "hello")
    }
}
