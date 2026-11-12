import Foundation

/// Tells the model today's date without disturbing provider prompt caches.
///
/// A model otherwise assumes its training cutoff is "now", which breaks web
/// research and anything else time-sensitive. The date cannot live in the
/// system prompt: that text opens the cached prefix, so a conversation
/// resumed on another day would lose its whole cache. It is appended to the
/// model-facing text of a user message instead, which is never rewritten
/// once sent, and only when the conversation has not been told this day yet.
nonisolated struct CurrentDatePromptStamp: Sendable {
    /// Last calendar day stated per conversation. Deliberately in memory
    /// only: after a relaunch the first message repeats the date, which costs
    /// one line and needs no persisted-session change.
    private var statedDays: [String: String] = [:]

    /// Returns `prompt` with the date note appended when `conversationID`
    /// has not received today's date yet, otherwise `prompt` unchanged.
    /// It records the day, so a caller whose turn is then refused must call
    /// `withdraw(conversationID:)`.
    mutating func stamped(
        _ prompt: String,
        conversationID: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        guard let conversationID else { return prompt }
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let day = "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
        guard statedDays[conversationID] != day else { return prompt }
        statedDays[conversationID] = day
        return prompt + "\n\n" + Self.note(for: now, calendar: calendar)
    }

    /// Forgets that `conversationID` was told the date, so its next message
    /// states it again. For a turn that was stamped and then never sent.
    mutating func withdraw(conversationID: String?) {
        guard let conversationID else { return }
        statedDays[conversationID] = nil
    }

    /// No time of day: it would differ on every message while adding nothing
    /// a model can act on. The format is locale-independent so the wording
    /// does not change with the user's system language.
    static func note(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        return "[Current date: \(formatter.string(from: date)) "
            + "(\(calendar.timeZone.identifier)). "
            + "Treat this as today, not your training cutoff.]"
    }
}
