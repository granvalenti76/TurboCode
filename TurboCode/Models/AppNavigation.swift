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
}

// MARK: - Settings Section

/// Settings tabs whose controls are connected to persisted product behavior.
public enum SettingsSection: String, Sendable, Hashable, CaseIterable {
    case general
    case editorialDesk
    case providers
    case reasoning
    case agents
    case shortcuts
}
