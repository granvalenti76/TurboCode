import Foundation
import Observation
import SwiftUI

// MARK: - SettingsStore

@MainActor
@Observable
public final class SettingsStore {
    public var theme: ThemePreference = .system {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
    }
    public var language: String = "en"
    public var fontSize: Double = 17.0 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    }
    public var maxChatWidth: Double = 820.0 {
        didSet { UserDefaults.standard.set(maxChatWidth, forKey: "maxChatWidth") }
    }
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
        let typographyVersion = defaults.integer(forKey: "chatTypographyVersion")
        if typographyVersion < 1 {
            fontSize = savedFontSize == 0 || savedFontSize == 15 ? 17 : savedFontSize
            defaults.set(fontSize, forKey: "fontSize")
            defaults.set(1, forKey: "chatTypographyVersion")
        } else {
            fontSize = savedFontSize == 0 ? 17 : savedFontSize
        }
        let savedMaxWidth = defaults.double(forKey: "maxChatWidth")
        maxChatWidth = savedMaxWidth == 0 ? 820.0 : savedMaxWidth
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

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
