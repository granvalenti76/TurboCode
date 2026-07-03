import Foundation
import Observation

// MARK: - SettingsStore

@MainActor
@Observable
public final class SettingsStore {
    public var theme: ThemePreference = .system
    public var language: String = "en"
    public var fontSize: Double = 14.0
    public var maxChatWidth: Double = 720.0
    public var workspacePaths: [String] = []

    public var openaiAPIKey: String = ""
    public var openaiBaseURL: String = ""
    public var anthropicAPIKey: String = ""
    public var anthropicBaseURL: String = ""
    public var deepseekAPIKey: String = ""
    public var deepseekBaseURL: String = ""

    // Write settings
    public var writeWorkspaceRoot: String = ""
    public var inlineCompletionEnabled: Bool = true

    // Shortcuts (stored as dictionary of command → key equivalent)
    public var keyboardShortcuts: [String: String] = [:]

    public init() {}

    public func loadFromUserDefaults() {
        let defaults = UserDefaults.standard
        theme = ThemePreference(rawValue: defaults.string(forKey: "theme") ?? "system") ?? .system
        language = defaults.string(forKey: "language") ?? "en"
        let savedFontSize = defaults.double(forKey: "fontSize")
        fontSize = savedFontSize == 0 ? 14.0 : savedFontSize
        let savedMaxWidth = defaults.double(forKey: "maxChatWidth")
        maxChatWidth = savedMaxWidth == 0 ? 720.0 : savedMaxWidth
        deepseekAPIKey = defaults.string(forKey: "deepseekAPIKey") ?? ""
        deepseekBaseURL = defaults.string(forKey: "deepseekBaseURL") ?? ""
        // TODO: load from Keychain for API keys
    }

    public func saveToUserDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(theme.rawValue, forKey: "theme")
        defaults.set(language, forKey: "language")
        defaults.set(fontSize, forKey: "fontSize")
        defaults.set(maxChatWidth, forKey: "maxChatWidth")
        defaults.set(deepseekBaseURL, forKey: "deepseekBaseURL")
    }
}

public enum ThemePreference: String, Sendable, Hashable, CaseIterable {
    case system
    case light
    case dark
}


