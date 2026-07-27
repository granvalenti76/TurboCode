import AppIntents
import Foundation

// MARK: - TurboCode Shortcuts Provider

/// Registers TurboCode's App Intents as system-wide Siri shortcuts.
///
/// Without this provider, intents are only accessible from the Shortcuts app
/// after manually adding them. The provider makes them discoverable by Siri
/// through the associated invocation phrases and assigns a branded tile color
/// in the Shortcuts gallery.
///
/// The provider is auto-detected at build time by `appintentsmetadataprocessor`
/// and requires no explicit registration in SwiftUI.
///
/// ## Constraints
///
/// - Every phrase **must** contain the `.applicationName` token, otherwise
///   `appintentsmetadataprocessor` rejects the entire provider at build time.
/// - Parameters of type `String`, `Int`, `Bool`, etc. cannot be interpolated
///   in AppShortcut phrases — only `AppEntity` and `AppEnum` types support
///   phrase interpolation. String parameters are collected by Siri through a
///   follow-up prompt instead.
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
struct TurboCodeShortcutsProvider: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        // -- Session Summary --
        // Summarizes the last N exchanges of the active conversation.
        // The exchangeCount parameter has a default, so Siri never needs to
        // prompt — the shortcut works with just the invocation phrase.
        AppShortcut(
            intent: SessionSummaryIntent(),
            phrases: [
                "Summarize my session in \(.applicationName)",
                "Summarize my TurboCode session with \(.applicationName)",
                "What's going on in \(.applicationName)",
                "Give me a session summary in \(.applicationName)",
            ],
            shortTitle: "Session Summary",
            systemImageName: "text.alignleft"
        )

        // -- Ask TurboCode --
        // Sends a prompt to the active model and returns the response.
        // The prompt parameter is String-typed, so it cannot be interpolated
        // in the phrase. Siri asks the user "What do you want to ask?" when
        // the Shortcut runs.
        AppShortcut(
            intent: AskTurboCodeIntent(),
            phrases: [
                "Ask \(.applicationName) something",
                "Ask TurboCode with \(.applicationName)",
                "Talk to \(.applicationName)",
            ],
            shortTitle: "Ask TurboCode",
            systemImageName: "sparkles.rectangle.stack"
        )

        // -- List Files --
        // Lists files and directories at a given path.
        // The path parameter is String-typed, so Siri prompts the user for
        // the path when the Shortcut runs.
        AppShortcut(
            intent: ListFilesIntent(),
            phrases: [
                "List files in \(.applicationName)",
                "List directory with \(.applicationName)",
            ],
            shortTitle: "List Files",
            systemImageName: "folder"
        )
    }

    /// Branded tile color shown in the Shortcuts app gallery.
    static let shortcutTileColor: ShortcutTileColor = .teal
}
