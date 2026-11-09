import Foundation

// MARK: - App Route

/// Destinations with a complete, user-visible workflow in the current release.
///
/// Keep this list deliberately smaller than the long-term product map: adding a
/// case makes it possible for shell navigation to expose that destination.
public enum AppRoute: String, Sendable, Hashable, CaseIterable {
    case chat
    case tools
    case skills
    /// The library of files Cowork sessions placed in their outboxes. Offered
    /// only in the Cowork domain; Coding results live in the workspace.
    case artifacts
    /// The built-in connectors and their switch for the active session.
    case connectors
}

// MARK: - Right Panel Mode

/// Inspector presentations backed by persisted data or a live service.
public enum RightPanelMode: String, Sendable, Hashable, CaseIterable {
    /// Transient operational state for the current delegated attempt.
    case activity
    case changes
    case commit
    /// A persisted directory snapshot selected from the conversation timeline.
    case workspaceListing
    /// The files a Cowork session placed in its outbox, with a preview. Read
    /// from the Mac-side outbox folder; it is not an export.
    case artifacts
}

// MARK: - Settings Section

/// Settings tabs whose controls are connected to persisted product behavior.
public enum SettingsSection: String, Sendable, Hashable, CaseIterable {
    case general
    case editorialDesk
    case providers
    case reasoning
    case agents
    case cowork
    case shortcuts
}
