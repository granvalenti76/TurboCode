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

            WriteSettingsView()
                .tabItem { Label("Write", systemImage: "pencil") }
                .tag(SettingsSection.write)

            AgentSettingsView()
                .tabItem { Label("Agents", systemImage: "wand.and.stars") }
                .tag(SettingsSection.agents)

            ShortcutSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsSection.shortcuts)

            DebugSettingsView()
                .tabItem { Label("Debug", systemImage: "ladybug") }
                .tag(SettingsSection.debug)
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

            Section("Language") {
                Picker("Language", selection: s.language) {
                    Text("English").tag("en")
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

                Toggle("Cursor spotlight", isOn: .constant(false))
            }

            Section("Workspace") {
                ForEach(settings.workspacePaths, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(path)
                            .font(.system(size: 11, design: .monospaced))
                        Spacer()
                        Button("-") {
                            settings.workspacePaths.removeAll { $0 == path }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                }

                Button("Add workspace path...") {
                    // TODO: NSOpenPanel
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

            Section("OpenAI") {
                SecureField("API Key", text: s.openaiAPIKey)
                    .textFieldStyle(.roundedBorder)
                TextField("Base URL", text: s.openaiBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }

            Section("Anthropic") {
                SecureField("API Key", text: s.anthropicAPIKey)
                    .textFieldStyle(.roundedBorder)
                TextField("Base URL", text: s.anthropicBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Write Settings

struct WriteSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let s = Bindable(settings)
        return Form {
            Section("Workspace") {
                HStack {
                    TextField("Workspace root", text: s.writeWorkspaceRoot)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("Browse...") {}
                        .controlSize(.small)
                }
            }

            Section("Editing") {
                Toggle("Inline AI completion", isOn: s.inlineCompletionEnabled)

                Picker("Font", selection: .constant("SF Mono")) {
                    Text("SF Mono").tag("SF Mono")
                    Text("Menlo").tag("Menlo")
                }
            }

            Section("Export") {
                Picker("Default format", selection: .constant("docx")) {
                    Text("DOCX").tag("docx")
                    Text("PDF").tag("pdf")
                    Text("Markdown").tag("md")
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

            Section("Orchestrator") {
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

                Text("Used for delegated coding work while Apple on-device runs the orchestrator.")
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
                ShortcutRow(label: "New Conversation", shortcut: "⇧⌘N")
                ShortcutRow(label: "Toggle Sidebar", shortcut: "⌘S")
                ShortcutRow(label: "Toggle Terminal", shortcut: "⌘J")
            }

            Section("Actions") {
                ShortcutRow(label: "Send Message", shortcut: "⌘⏎")
                ShortcutRow(label: "Interrupt", shortcut: "⎋")
                ShortcutRow(label: "Toggle Plan Mode", shortcut: "⌘P")
                ShortcutRow(label: "Choose Workspace", shortcut: "⇧⌘O")
            }

            Section("Views") {
                ShortcutRow(label: "Settings", shortcut: "⌘,")
                ShortcutRow(label: "Focus Mode", shortcut: "⇧⌘D")
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

// MARK: - Debug Settings

struct DebugSettingsView: View {
    var body: some View {
        Form {
            Section("Runtime") {
                Toggle("LLM debug log", isOn: .constant(false))

                HStack {
                    Text("Log path")
                    Spacer()
                    Text("~/Library/Application Support/TurboCode/logs")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Diagnostics") {
                Button("View runtime logs...") {}
                Button("Restart runtime...") {}
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
