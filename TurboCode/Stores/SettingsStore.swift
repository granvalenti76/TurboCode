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
    public var maxChatWidth: Double = 1440.0 {
        didSet { UserDefaults.standard.set(maxChatWidth, forKey: "maxChatWidth") }
    }
    public var workspacePaths: [String] = []

    public var agentTuning: AgentTuningConfig = .default {
        didSet {
            guard !isLoadingAgentTuning else { return }
            do {
                let validated = try agentTuning.validated()
                try TurboCodeConfig.shared.saveAgentTuning(validated)
                agentTuningError = nil
                ChatStore.shared?.applyAgentTuning(validated)
            } catch {
                agentTuningError = error.localizedDescription
            }
        }
    }
    public private(set) var agentTuningError: String?
    public private(set) var remoteModels: [RemoteModelConfig] = RemoteModelConfig.defaults

    public var orchestratorModelOptions: [RemoteModelConfig] {
        remoteModels.filter(\.enabled)
    }

    public var selectedOrchestratorModel: RemoteModelConfig? {
        remoteModels.first(where: { $0.id == agentTuning.orchestrator.delegateModelID })
    }

    public var openaiAPIKey: String = ""
    public var openaiBaseURL: String = ""
    public var anthropicAPIKey: String = ""
    public var anthropicBaseURL: String = ""
    public var deepseekAPIKey: String = "" {
        didSet {
            guard !isLoadingCredentials else { return }
            do {
                try CredentialStore.set(deepseekAPIKey, for: "deepseek")
                credentialError = nil
                reloadRemoteModels()
                ChatStore.shared?.reloadRemoteModels()
            } catch {
                credentialError = error.localizedDescription
            }
        }
    }
    public private(set) var credentialError: String?

    // Write settings
    public var writeWorkspaceRoot: String = ""
    public var inlineCompletionEnabled: Bool = true

    // Shortcuts (stored as dictionary of command → key equivalent)
    public var keyboardShortcuts: [String: String] = [:]

    private var isLoadingCredentials = false
    private var isLoadingAgentTuning = false

    public init() {}

    public func loadFromUserDefaults() {
        let defaults = UserDefaults.standard
        theme = ThemePreference(rawValue: defaults.string(forKey: "theme") ?? "system") ?? .system
        language = defaults.string(forKey: "language") ?? "en"
        let savedFontSize = defaults.double(forKey: "fontSize")
        let typographyVersion = defaults.integer(forKey: "chatTypographyVersion")
        if typographyVersion < 3 {
            // Version 3 restores the reference reading scale. The values 15,
            // 16, and 17 were defaults across earlier typography revisions;
            // other slider values remain explicit user choices.
            fontSize = savedFontSize == 0
                || savedFontSize == 15
                || savedFontSize == 16
                || savedFontSize == 17
                ? 17
                : savedFontSize
            defaults.set(fontSize, forKey: "fontSize")
            defaults.set(3, forKey: "chatTypographyVersion")
        } else {
            fontSize = savedFontSize == 0 ? 17 : savedFontSize
        }
        let savedMaxWidth = defaults.double(forKey: "maxChatWidth")
        let layoutWidthVersion = defaults.integer(forKey: "chatLayoutWidthVersion")
        if layoutWidthVersion < 1 {
            // TurboCode is a workbench: migrate the old article-like column to
            // a desktop width while keeping the preference adjustable.
            maxChatWidth = max(savedMaxWidth, 1440.0)
            defaults.set(maxChatWidth, forKey: "maxChatWidth")
            defaults.set(1, forKey: "chatLayoutWidthVersion")
        } else {
            maxChatWidth = savedMaxWidth == 0 ? 1440.0 : savedMaxWidth
        }
        reloadAgentTuning()
        reloadRemoteModels()
        // Do not read provider secrets while restoring general settings. The
        // Provider pane loads this value only when the user opens it.
        ChatStore.shared?.reloadRemoteModels()
    }

    /// Loads the existing provider secret for deliberate credential
    /// management in Settings, keeping normal application launch lazy.
    public func loadDeepSeekCredentialForSettings() {
        guard !isLoadingCredentials else { return }
        isLoadingCredentials = true
        let defaults = UserDefaults.standard
        if let stored = CredentialStore.value(for: "deepseek") {
            deepseekAPIKey = stored
        } else if let legacy = defaults.string(forKey: "deepseekAPIKey"), !legacy.isEmpty {
            // Migrate the pre-Keychain value only after the user explicitly
            // opens provider settings, keeping launch free of secret access.
            deepseekAPIKey = legacy
            try? CredentialStore.set(legacy, for: "deepseek")
            defaults.removeObject(forKey: "deepseekAPIKey")
        } else {
            deepseekAPIKey = ""
        }
        isLoadingCredentials = false
        credentialError = nil
    }

    public func reloadRemoteModels() {
        remoteModels = (try? TurboCodeConfig.shared.loadRemoteModels())
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? RemoteModelConfig.defaults
    }

    public func isConfigured(_ model: RemoteModelConfig) -> Bool {
        guard let credential = model.credential else { return true }
        return !(CredentialStore.value(for: credential) ?? "").isEmpty
    }

    public func reloadAgentTuning() {
        isLoadingAgentTuning = true
        defer { isLoadingAgentTuning = false }
        do {
            let loaded = try TurboCodeConfig.shared.loadAgentTuning()
            agentTuning = loaded
            agentTuningError = nil
            ChatStore.shared?.applyAgentTuning(loaded)
        } catch {
            agentTuningError = error.localizedDescription
        }
    }

    public func saveToUserDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(theme.rawValue, forKey: "theme")
        defaults.set(language, forKey: "language")
        defaults.set(fontSize, forKey: "fontSize")
        defaults.set(maxChatWidth, forKey: "maxChatWidth")
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
