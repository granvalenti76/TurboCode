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

/// Settings panes whose controls are connected to persisted product behavior.
///
/// Case order is the sidebar order. Every pane belongs to exactly one
/// `SettingsGroup`, so the sidebar reads as five purposes instead of a flat
/// list of unrelated tabs. `cowork` keeps its source name (the UI says
/// "Studio") per the Studio boundary in AGENTS.md.
public enum SettingsSection: String, Sendable, Hashable, CaseIterable {
    case general
    case shortcuts
    case providers
    case reasoning
    case routing
    case behavior
    case execution
    case cowork
    case editorialDesk
    case permissions

    public var group: SettingsGroup {
        switch self {
        case .general, .shortcuts: .turboCode
        case .providers, .reasoning, .routing: .intelligence
        case .behavior, .execution: .agents
        case .cowork, .editorialDesk: .workspaces
        case .permissions: .trust
        }
    }

    public var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Keyboard Shortcuts"
        case .providers: "Providers"
        case .reasoning: "Reasoning"
        case .routing: "Dynamic Routing"
        case .behavior: "Behavior"
        case .execution: "Execution"
        case .cowork: "Studio"
        case .editorialDesk: "Editorial Desk"
        case .permissions: "Permissions"
        }
    }

    public var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .providers: "network"
        case .reasoning: "brain"
        case .routing: "arrow.triangle.branch"
        case .behavior: "text.bubble"
        case .execution: "terminal"
        case .cowork: "shippingbox"
        case .editorialDesk: "newspaper"
        case .permissions: "lock.shield"
        }
    }

    /// One sentence shown under the pane title that states what the pane
    /// decides, so each pane opens with its purpose rather than its controls.
    public var summary: String {
        switch self {
        case .general: "How TurboCode looks and how wide the conversation reads."
        case .shortcuts: "Keyboard shortcuts available in the main window."
        case .providers: "Credentials for remote providers. Endpoints come from models.json; keys stay in the Keychain."
        case .reasoning: "How much remote models reason before they answer."
        case .routing: "An optional on-device model that chooses which tools each response can use."
        case .behavior: "How agents answer, check their work, and hand tasks to a worker."
        case .execution: "Limits for the commands agents run on this Mac."
        case .cowork: "An isolated Linux virtual machine for builds, scripts, and artifacts."
        case .editorialDesk: "Sections and article types offered in the Editorial Desk."
        case .permissions: "What agents can reach outside your workspace. Each item stays off until you turn it on."
        }
    }
}

/// Purpose groups shown as sidebar sections in Settings, in display order.
public enum SettingsGroup: String, Sendable, Hashable, CaseIterable {
    case turboCode
    case intelligence
    case agents
    case workspaces
    case trust

    public var title: String {
        switch self {
        case .turboCode: "TurboCode"
        case .intelligence: "Intelligence"
        case .agents: "Agents"
        case .workspaces: "Workspaces"
        case .trust: "Trust"
        }
    }

    /// The panes of this group, in sidebar order.
    public var sections: [SettingsSection] {
        SettingsSection.allCases.filter { $0.group == self }
    }
}
