import Foundation

// MARK: - App Route

public enum AppRoute: String, Sendable, Hashable, CaseIterable {
    case chat
    case write
    case settings
    case tools
    case claw
    case skills
    case workflow
}

// MARK: - Right Panel Mode

public enum RightPanelMode: String, Sendable, Hashable {
    case todo
    case changes
    case commit
    /// A persisted directory snapshot selected from the conversation timeline.
    case workspaceListing
    case browser
    case file
    case plan
    case sddAI = "sdd-ai"
    case subagents
}

// MARK: - Settings Section

public enum SettingsSection: String, Sendable, Hashable, CaseIterable {
    case general
    case providers
    case write
    case mediaGeneration = "media-generation"
    case speechToText = "speech-to-text"
    case agents
    case archives
    case worktree
    case memory
    case shortcuts
    case claw
    case updates
    case terminal
    case debug
}
