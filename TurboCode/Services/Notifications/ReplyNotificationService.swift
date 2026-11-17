import AppKit
import Foundation
import OSLog
import UserNotifications

/// Posts a discreet system notification when a reply finishes unseen, and
/// opens that chat when the notification is clicked.
///
/// `BackgroundTurnStore` decides *whether* a finish was unseen; this type
/// only builds and delivers the notification. Permission is requested the
/// first time a notification is actually needed, not at launch. No sound:
/// the notification should not interrupt whatever the user is doing.
@MainActor
final class ReplyNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let threadIDKey = "threadID"
    /// Delivery and clicks are logged without content: only chat IDs.
    nonisolated static let log = Logger(subsystem: "art.granvalenti.turbocode", category: "ReplyNotifications")

    private let center: UNUserNotificationCenter
    /// Opens the chat behind a clicked notification.
    var openThread: (String) -> Void = { _ in }

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func post(_ content: ReplyNotificationContent, threadID: String) {
        Task {
            guard await isAuthorized() else {
                Self.log.info("Reply notification skipped: not authorized")
                return
            }
            let notification = UNMutableNotificationContent()
            notification.title = content.title
            notification.body = content.body
            // Groups several replies of one chat in Notification Center.
            notification.threadIdentifier = threadID
            notification.userInfo = [Self.threadIDKey: threadID]
            // One pending notification per chat: a newer reply replaces it.
            let request = UNNotificationRequest(
                identifier: "reply-\(threadID)",
                content: notification,
                trigger: nil
            )
            do {
                try await center.add(request)
                Self.log.info("Reply notification posted for \(threadID, privacy: .public)")
            } catch {
                Self.log.error("Reply notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func isAuthorized() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert])) ?? false
        default:
            return false
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Notifications are posted only while TurboCode is in the background.
    /// If the user comes back before delivery, keep it in Notification
    /// Center but show no banner over the app they are already using.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let threadID = response.notification.request.content.userInfo[Self.threadIDKey] as? String
        else {
            Self.log.error("Reply notification clicked without a chat ID")
            return
        }
        Self.log.info("Reply notification clicked for \(threadID, privacy: .public)")
        await MainActor.run {
            NSApp.activate()
            // Bring back the existing main window, even when minimized,
            // instead of letting the system open a new one. SwiftUI names
            // WindowGroup windows after the scene id ("main-…").
            if let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue.hasPrefix("main") == true
            }) {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
            openThread(threadID)
        }
    }
}

/// Title and text of a reply notification. Pure, so the excerpt rules are
/// testable without the notification center.
nonisolated struct ReplyNotificationContent: Equatable, Sendable {
    static let excerptLimit = 140

    let title: String
    let body: String

    init(chatTitle: String, outcome: TurnOutcome?, reply: String?, includeExcerpt: Bool) {
        title = chatTitle
        if case .failed = outcome {
            body = "The reply stopped with an error."
        } else if includeExcerpt, let reply, case let excerpt = Self.excerpt(from: reply), !excerpt.isEmpty {
            body = excerpt
        } else {
            body = "The reply is ready."
        }
    }

    /// A short plain-text opening of the reply: code blocks dropped, Markdown
    /// markers and link targets removed, whitespace collapsed, and the text
    /// cut at a word boundary.
    static func excerpt(from markdown: String) -> String {
        var text = markdown.replacingOccurrences(
            of: "```[\\s\\S]*?(```|$)", with: " ", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "!?\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?m)^\\s{0,3}(#{1,6}|>|[-*+]|\\d+\\.)\\s+", with: "", options: .regularExpression
        )
        text = text.replacingOccurrences(of: "[*_`~]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > excerptLimit else { return text }
        let cut = text.prefix(excerptLimit)
        let wordEnd = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return wordEnd.trimmingCharacters(in: .whitespaces) + "…"
    }
}
