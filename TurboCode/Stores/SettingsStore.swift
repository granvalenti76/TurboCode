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
    /// The newsroom taxonomy used by Editorial Desk metadata menus and
    /// persisted independently from provider and agent configuration.
    public var editorialDeskCatalog: EditorialDeskCatalog = .default {
        didSet {
            guard !isLoadingEditorialDeskCatalog else { return }
            saveEditorialDeskCatalog()
        }
    }

    public var agentTuning: AgentTuningConfig = .default {
        didSet {
            guard !isLoadingAgentTuning else { return }
            do {
                let validated = try agentTuning.validated()
                try TurboCodeConfig.shared.saveAgentTuning(validated)
                agentTuningError = nil
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
    public private(set) var deepSeekCredentialConfigured = false
    public var deepseekAPIKey: String = "" {
        didSet {
            guard !isLoadingCredentials else { return }
            do {
                try CredentialStore.set(deepseekAPIKey, for: "deepseek")
                deepSeekCredentialConfigured = !deepseekAPIKey.isEmpty
                credentialError = nil
                reloadRemoteModels()
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
    private var isLoadingEditorialDeskCatalog = false

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
        loadEditorialDeskCatalog()
        // Do not read provider secrets while restoring general settings. The
        // Provider pane loads this value only when the user opens it.
    }

    /// Loads only credential state for the provider pane.
    ///
    /// The existing secret stays in the Keychain and is never copied into the
    /// observable settings model. The field is intentionally an entry field
    /// for replacing the secret, not a mirror of the stored credential.
    public func loadDeepSeekCredentialForSettings() {
        guard !isLoadingCredentials else { return }
        isLoadingCredentials = true
        let defaults = UserDefaults.standard
        if let legacy = defaults.string(forKey: "deepseekAPIKey"), !legacy.isEmpty {
            // Migrate the legacy value only when the user opens provider
            // settings; normal launch remains free of credential access.
            try? CredentialStore.set(legacy, for: "deepseek")
            defaults.removeObject(forKey: "deepseekAPIKey")
        }
        deepseekAPIKey = ""
        deepSeekCredentialConfigured = CredentialStore.contains(account: "deepseek")
        isLoadingCredentials = false
        credentialError = nil
    }

    public func reloadRemoteModels() {
        remoteModels = (try? TurboCodeConfig.shared.loadRemoteModels())
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? RemoteModelConfig.defaults
        // PCC-RETIREMENT: remove this defensive filter with the legacy model
        // role once old settings files no longer need compatibility handling.
        remoteModels.removeAll { $0.isRetiredPCC }
    }

    public func isConfigured(_ model: RemoteModelConfig) -> Bool {
        guard let credential = model.credential else { return true }
        return CredentialStore.contains(account: credential)
    }

    public func reloadAgentTuning() {
        isLoadingAgentTuning = true
        defer { isLoadingAgentTuning = false }
        do {
            let loaded = try TurboCodeConfig.shared.loadAgentTuning()
            agentTuning = loaded
            agentTuningError = nil
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

    private func loadEditorialDeskCatalog() {
        isLoadingEditorialDeskCatalog = true
        defer { isLoadingEditorialDeskCatalog = false }

        guard let data = UserDefaults.standard.data(forKey: "editorialDeskCatalog"),
              let catalog = try? JSONDecoder().decode(
                  EditorialDeskCatalog.self,
                  from: data
              ) else {
            editorialDeskCatalog = .default
            saveEditorialDeskCatalog()
            return
        }
        if isLegacyEditorialMockCatalog(catalog) {
            editorialDeskCatalog = .default
            saveEditorialDeskCatalog()
        } else {
            let merged = catalogByAddingDefaults(to: catalog)
            editorialDeskCatalog = merged
            if merged != catalog {
                saveEditorialDeskCatalog()
            }
        }
    }

    /// Seeds newly shipped defaults without replacing or reordering entries
    /// that the user already configured in Settings.
    private func catalogByAddingDefaults(
        to catalog: EditorialDeskCatalog
    ) -> EditorialDeskCatalog {
        var merged = catalog
        for section in EditorialDeskCatalog.default.sections where !merged.sections.contains(where: {
            $0.name.caseInsensitiveCompare(section.name) == .orderedSame
        }) {
            merged.sections.append(section)
        }
        for type in EditorialDeskCatalog.default.types where !merged.types.contains(where: {
            $0.name.caseInsensitiveCompare(type.name) == .orderedSame
        }) {
            merged.types.append(type)
        }
        return merged
    }

    private func saveEditorialDeskCatalog() {
        guard let data = try? JSONEncoder().encode(editorialDeskCatalog) else { return }
        UserDefaults.standard.set(data, forKey: "editorialDeskCatalog")
    }

    private func isLegacyEditorialMockCatalog(_ catalog: EditorialDeskCatalog) -> Bool {
        guard catalog.sections.count == 1,
              catalog.types.count == 1,
              catalog.sections[0].name == "Politica",
              catalog.sections[0].systemImage == "building.columns",
              catalog.types[0].name == "Breaking",
              catalog.types[0].systemImage == "bolt.fill",
              catalog.types[0].colorHex.caseInsensitiveCompare("#FF3B30") == .orderedSame else {
            return false
        }
        return true
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
