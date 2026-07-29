import SwiftUI

// MARK: - SettingsTabView — native macOS settings with a sidebar-style TabView

struct SettingsTabView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var selectedSection: SettingsSection = .general

    var body: some View {
        TabView(selection: $selectedSection) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
                .tag(SettingsSection.general)

            ProviderSettingsView()
                .tabItem { Label("Providers", systemImage: "network") }
                .tag(SettingsSection.providers)

            AgentSettingsView()
                .tabItem { Label("Agents", systemImage: "wand.and.stars") }
                .tag(SettingsSection.agents)

            ShortcutSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsSection.shortcuts)

        }
        .tabViewStyle(.sidebarAdaptable)
        .frame(minWidth: 600, minHeight: 400)
        .environment(settings)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let s = Bindable(settings)
        return Form {
            Section("Appearance") {
                Picker("Theme", selection: s.theme) {
                    Text("System").tag(ThemePreference.system)
                    Text("Light").tag(ThemePreference.light)
                    Text("Dark").tag(ThemePreference.dark)
                }

                HStack {
                    Text("Chat text size")
                    Slider(value: s.fontSize, in: 13...20, step: 1)
                    Text("\(Int(settings.fontSize))")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 24)
                }
            }

            Section("Chat") {
                HStack {
                    Text("Content width")
                    Slider(value: s.maxChatWidth, in: 640...1600, step: 20)
                    Text("\(Int(settings.maxChatWidth))")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 40)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Provider Settings

struct ProviderSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let s = Bindable(settings)
        return Form {
            Section("DeepSeek") {
                SecureField("API Key", text: s.deepseekAPIKey)
                    .textFieldStyle(.roundedBorder)

                Label(
                    settings.deepseekAPIKey.isEmpty ? "Not configured" : "Configured",
                    systemImage: settings.deepseekAPIKey.isEmpty ? "key.slash" : "checkmark.circle"
                )
                .foregroundStyle(settings.deepseekAPIKey.isEmpty ? Color.secondary : Color.green)

                if let error = settings.credentialError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Agent Settings

struct AgentSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let s = Bindable(settings)
        return Form {
            Section("Responses") {
                Picker("Detail", selection: s.agentTuning.agent.responseStyle) {
                    Text("Concise").tag(AgentResponseStyle.concise)
                    Text("Balanced").tag(AgentResponseStyle.balanced)
                    Text("Detailed").tag(AgentResponseStyle.detailed)
                }
                Toggle("Verify source changes", isOn: s.agentTuning.agent.verifiesChanges)
            }

            Section("Delegated Worker") {
                Picker(
                    "Powerful model",
                    selection: s.agentTuning.orchestrator.delegateModelID
                ) {
                    if settings.selectedOrchestratorModel == nil {
                        Text("Unavailable (\(settings.agentTuning.orchestrator.delegateModelID))")
                            .tag(settings.agentTuning.orchestrator.delegateModelID)
                    }
                    ForEach(settings.orchestratorModelOptions) { model in
                        Text(model.name)
                            .tag(model.id)
                            .disabled(!settings.isConfigured(model))
                    }
                }

                Text("Used by structured coordinator profiles and experimental on-device delegation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let selected = settings.selectedOrchestratorModel,
                   !settings.isConfigured(selected) {
                    Label(
                        "\(selected.name) requires its credential before it can be used.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                } else if settings.selectedOrchestratorModel == nil {
                    Label(
                        "The selected model ID is not present in models.json.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("Execution") {
                Stepper(
                    value: s.agentTuning.execution.defaultCommandTimeoutSeconds,
                    in: 5...settings.agentTuning.execution.maximumCommandTimeoutSeconds,
                    step: 5
                ) {
                    LabeledContent("Command timeout") {
                        Text("\(settings.agentTuning.execution.defaultCommandTimeoutSeconds)s")
                            .monospacedDigit()
                    }
                }

                Stepper(
                    value: s.agentTuning.execution.maximumToolOutputCharacters,
                    in: 1_000...30_000,
                    step: 1_000
                ) {
                    LabeledContent("Maximum tool output") {
                        Text("\(settings.agentTuning.execution.maximumToolOutputCharacters)")
                            .monospacedDigit()
                    }
                }

                Toggle("Allow command network access", isOn: s.agentTuning.execution.allowNetworkAccess)
            }

            Section("Skills") {
                Toggle("Discover user skills", isOn: s.agentTuning.skills.discoversUserSkills)
            }

            Section {
                Button {
                    settings.reloadAgentTuning()
                } label: {
                    Label("Reload Configuration", systemImage: "arrow.clockwise")
                }

                if let error = settings.agentTuningError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Shortcut Settings

struct ShortcutSettingsView: View {
    var body: some View {
        Form {
            Section("Navigation") {
                ShortcutRow(label: "New Chat", shortcut: "⌘N")
                ShortcutRow(label: "Toggle Sidebar", shortcut: "⌘S")
            }

            Section("Actions") {
                ShortcutRow(label: "Choose Workspace", shortcut: "⇧⌘O")
            }

            Section("Views") {
                ShortcutRow(label: "Settings", shortcut: "⌘,")
                ShortcutRow(label: "Chat", shortcut: "⌘1")
                ShortcutRow(label: "Custom Profiles", shortcut: "⌘2")
                ShortcutRow(label: "Tools", shortcut: "⌘3")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ShortcutRow: View {
    let label: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(shortcut)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}
