import AppKit
import SwiftUI

struct SkillsView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel = SkillsViewModel()
    @State private var newProfilePresented = false
    @State private var suggestedBaseModel: ProfileBaseModelID = .onDevice
    @State private var suggestedDelegationEnabled = false
    @State private var suggestedCopyDefaults = false
    @State private var deleteConfirmationPresented = false
    @State private var capabilityKind: CapabilityKind = .tools
    @State private var includedDropTargeted = false
    @State private var availableDropTargeted = false
    @State private var hoveredTool: ToolHoverPresentation?
    @State private var pendingToolHover: Task<Void, Never>?

    private enum CapabilityKind: String, CaseIterable, Identifiable {
        case tools = "Tools"
        case skills = "Skills"
        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            profileLibrary
                .frame(width: 272)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .task {
            settings.reloadRemoteModels()
            viewModel.reload()
            if let requestedRole = chatStore.consumeProfileCreationRequest() {
                // Defer the nested sheet until the profile library itself has
                // joined the presented hierarchy.
                suggestedDelegationEnabled = requestedRole == .coordinatorWorker
                suggestedBaseModel = suggestedDelegationEnabled
                    ? .deepseek
                    : .onDevice
                suggestedCopyDefaults = false
                await Task.yield()
                newProfilePresented = true
            }
        }
        .onDisappear {
            pendingToolHover?.cancel()
        }
        .sheet(isPresented: $newProfilePresented) {
            NewDynamicProfileSheet(
                initialBaseModel: suggestedBaseModel,
                initialDelegationEnabled: suggestedDelegationEnabled,
                initialCopyDefaults: suggestedCopyDefaults,
                modelOptions: viewModel.profileModelOptions(settings: settings),
                delegationOptions: viewModel.delegationOptions(settings: settings),
                workerOptions: viewModel.workerOptions(settings: settings),
                codexModels: chatStore.codexModels,
                codexDefaultReasoningOptions: chatStore.codexReasoningOptions,
                initialCodexModelID: chatStore.codexPreferredModel?.id,
                initialCodexReasoningEffort: chatStore.codexReasoningEffort
            ) {
                name,
                summary,
                model,
                worker,
                codexModel,
                codexReasoning,
                delegationEnabled,
                copyDefaults in
                let created = viewModel.create(
                    name: name,
                    summary: summary,
                    baseModelID: model,
                    workerModelID: worker,
                    codexModelID: codexModel,
                    codexReasoningEffort: codexReasoning,
                    includeDelegation: delegationEnabled,
                    copyDefaults: copyDefaults,
                    settings: settings
                )
                if created,
                   case .custom(let profileID) = viewModel.selection {
                    Task {
                        await chatStore.reloadDynamicProfiles(selecting: profileID)
                    }
                }
                return created
            }
        }
        .alert("Delete Profile?", isPresented: $deleteConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                viewModel.deleteSelected()
                Task { await chatStore.reloadDynamicProfiles() }
            }
                .disabled(chatStore.busy)
        } message: {
            Text("This removes the custom profile. Models, tools, and installed skills are not deleted.")
        }
        .alert("Profile Error", isPresented: errorPresented) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "The profile could not be updated.")
        }
    }

    private var profileLibrary: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Profiles")
                        .font(.system(size: 19, weight: .semibold))
                    Text("\(viewModel.profiles.count) custom")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    suggestedBaseModel = .onDevice
                    suggestedDelegationEnabled = false
                    suggestedCopyDefaults = false
                    newProfilePresented = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .help("New Profile")
                .accessibilityLabel("New Profile")
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 10)

            List(selection: selectionBinding) {
                Section("Default Profiles") {
                    ForEach(ProfileBaseModelID.builtInCases) { modelID in
                        profileRow(
                            title: modelID.displayName,
                            subtitle: "Built in",
                            icon: modelID.systemImage,
                            active: chatStore.activeDynamicProfileID == nil
                                && chatStore.activeBaseModelID == modelID
                        )
                        .tag(ProfileLibrarySelection.builtIn(modelID))
                    }
                }
                Section("Custom Profiles") {
                    ForEach(viewModel.profiles) { profile in
                        profileRow(
                            title: profile.name,
                            subtitle: profile.baseModelID.displayName,
                            icon: "person.crop.rectangle.stack",
                            active: chatStore.activeDynamicProfileID == profile.id
                        )
                        .tag(ProfileLibrarySelection.custom(profile.id))
                        .contextMenu {
                            Button("Use Profile") {
                                Task { await chatStore.selectDynamicProfile(profile.id) }
                            }
                                .disabled(chatStore.busy)
                            Divider()
                            Button("Delete", role: .destructive) {
                                viewModel.select(.custom(profile.id))
                                deleteConfirmationPresented = true
                            }
                            .disabled(chatStore.busy)
                        }
                    }
                    if viewModel.profiles.isEmpty {
                        Text("No custom profiles")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Text("\(viewModel.installedSkills.count) installed skills")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    revealSkillsDirectory()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal Skills in Finder")
                Button {
                    viewModel.reload()
                    Task {
                        await chatStore.reloadSkills()
                        await chatStore.reloadDynamicProfiles()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload Profiles and Skills")
            }
            .padding(10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func profileRow(
        title: String,
        subtitle: String,
        icon: String,
        active: Bool
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if active {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Active profile")
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var detail: some View {
        switch viewModel.selection {
        case .builtIn(let modelID):
            builtInDetail(modelID)
        case .custom:
            if let draft = viewModel.draft {
                customDetail(draft)
            } else {
                ContentUnavailableView("Profile Unavailable", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private func builtInDetail(_ modelID: ProfileBaseModelID) -> some View {
        let option = viewModel.modelOption(for: modelID, settings: settings)
        let defaultTools = ModelToolCatalog.descriptors.filter { option.defaultToolIDs.contains($0.id) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(modelID.displayName, systemImage: modelID.systemImage)
                            .font(.system(size: 27, weight: .semibold))
                        Text(option.subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Create Override") {
                        suggestedBaseModel = modelID
                        suggestedCopyDefaults = true
                        newProfilePresented = true
                    }
                    Button("Use Default") {
                        Task { await chatStore.selectBuiltInProfile(modelID) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!option.isAvailable || chatStore.busy)
                }

                infoBanner(
                    icon: "lock.shield",
                    title: "Built-in profile",
                    text: "Defaults stay unchanged. Create an override to choose an explicit set of tools and skills."
                )

                sectionCard(
                    title: "Default Capabilities",
                    subtitle: "These capabilities are managed by TurboCode and may evolve with the model."
                ) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 8)], spacing: 8) {
                        ForEach(defaultTools) { tool in
                            capabilityBadge(icon: tool.systemImage, title: tool.name, subtitle: tool.id.runtimeName)
                                .toolInformationHoverCard(
                                    tool,
                                    availability: "Included in the \(modelID.displayName) default profile",
                                    isAvailable: true
                                )
                        }
                    }
                    if !viewModel.installedSkills.isEmpty, option.defaultToolIDs.contains(.loadSkill) {
                        Divider()
                        Text("All installed skills are available on demand.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if !viewModel.discoveredTypeScriptPlugins.isEmpty {
                    typeScriptPluginSection()
                }
            }
            .padding(28)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func customDetail(_ draft: UserDynamicProfile) -> some View {
        let option = viewModel.modelOption(for: draft.baseModelID, settings: settings)
        let workerOption = viewModel.workerOptions(settings: settings).first {
            $0.id.rawValue == draft.resolvedWorkerModelID(
                fallback: ProfileBaseModelID.llama.rawValue
            )
        }
        let routeIsAvailable = option.isAvailable
            && (
                !draft.usesDelegation
                    || workerOption?.isAvailable == true
            )
            && codexConfigurationIsAvailable(for: draft)
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom Profile")
                            .font(.system(size: 27, weight: .semibold))
                        Text("Only included tools and skills are loaded into the model session.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        deleteConfirmationPresented = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(chatStore.busy)
                    Button("Revert") { viewModel.discardChanges() }
                        .disabled(!viewModel.isDirty)
                    Button("Save") {
                        if viewModel.save() {
                            Task { await chatStore.reloadDynamicProfiles() }
                        }
                    }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!viewModel.canSave || chatStore.busy)
                    Button("Use Profile") {
                        if !viewModel.isDirty || viewModel.save() {
                            Task {
                                await chatStore.reloadDynamicProfiles()
                                await chatStore.selectDynamicProfile(draft.id)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!routeIsAvailable || chatStore.busy)
                }

                if !option.isAvailable {
                    infoBanner(
                        icon: "exclamationmark.triangle",
                        title: "Model unavailable",
                        text: "Enable and configure \(draft.baseModelID.displayName) before using this profile."
                    )
                } else if draft.usesDelegation,
                          workerOption?.isAvailable != true {
                    infoBanner(
                        icon: "exclamationmark.triangle",
                        title: "Worker unavailable",
                        text: "Enable and configure the selected worker before using this profile."
                    )
                } else if !codexConfigurationIsAvailable(for: draft) {
                    infoBanner(
                        icon: "exclamationmark.triangle",
                        title: "Codex configuration unavailable",
                        text: "Choose a Codex model and reasoning level that are available to the signed-in account."
                    )
                }

                sectionCard(title: "Profile", subtitle: "A recognizable name and the model this profile controls.") {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                        GridRow {
                            Text("Name").foregroundStyle(.secondary)
                            TextField("Profile name", text: nameBinding)
                                .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("Description").foregroundStyle(.secondary)
                            TextField("What is this profile for?", text: summaryBinding)
                                .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("Model").foregroundStyle(.secondary)
                            HStack(spacing: 14) {
                                Picker("Model", selection: baseModelBinding) {
                                    ForEach(viewModel.profileModelOptions(settings: settings)) { model in
                                        Label(model.id.displayName, systemImage: model.id.systemImage)
                                            .tag(model.id)
                                            .disabled(
                                                draft.usesDelegation
                                                    && !ProfileBaseModelID.delegationCases.contains(model.id)
                                            )
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 280, alignment: .leading)
                                Toggle("Greedy mode", isOn: greedyModeBinding)
                                    .toggleStyle(.checkbox)
                                    .disabled(draft.baseModelID == .deepseek || draft.usesDelegation)
                                Text(draft.baseModelID == .deepseek
                                        ? "Unavailable with DeepSeek Thinking."
                                        : draft.usesDelegation
                                            ? "Delegated profiles use the selected worker."
                                            : "Always pick the most likely token.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if draft.baseModelID == .codex {
                            GridRow {
                                Text("Codex model").foregroundStyle(.secondary)
                                Picker("Codex model", selection: codexModelBinding) {
                                    Text("Codex Default").tag("")
                                    if let savedID = draft.codexModelID,
                                       !chatStore.codexModels.contains(where: { $0.id == savedID }) {
                                        Text(savedID).tag(savedID)
                                    }
                                    ForEach(chatStore.codexModels) { model in
                                        Text(model.displayName).tag(model.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 280, alignment: .leading)
                            }
                            GridRow {
                                Text("Reasoning").foregroundStyle(.secondary)
                                Picker("Reasoning", selection: codexReasoningBinding) {
                                    Text("Model Default").tag("")
                                    if let savedEffort = draft.codexReasoningEffort,
                                       !codexReasoningOptions(for: draft.codexModelID).contains(where: {
                                           $0.reasoningEffort == savedEffort
                                       }) {
                                        Text("\(savedEffort.displayName) (Unavailable)")
                                            .tag(savedEffort.rawValue)
                                            .disabled(true)
                                    }
                                    ForEach(
                                        codexReasoningOptions(for: draft.codexModelID),
                                        id: \.reasoningEffort.rawValue
                                    ) { option in
                                        Text(option.reasoningEffort.displayName)
                                            .tag(option.reasoningEffort.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 280, alignment: .leading)
                            }
                        }
                    }
                }

                if draft.usesDelegation {
                    sectionCard(
                        title: "Delegation",
                        subtitle: "Delegate Task is included. Choose the model that handles bounded implementation work."
                    ) {
                        DisclosureGroup {
                            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                                GridRow {
                                    Text("Worker").foregroundStyle(.secondary)
                                    Picker("Worker", selection: workerModelBinding) {
                                        ForEach(viewModel.workerOptions(settings: settings)) { model in
                                            Label(model.id.displayName, systemImage: model.id.systemImage)
                                                .tag(model.id.rawValue)
                                                .disabled(!model.isAvailable)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: 280, alignment: .leading)
                                }
                            }
                            Text("The worker choice is stored with this profile and used whenever Delegate Task runs.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 3)

                            workerToolDisclosure(draft: draft)
                        } label: {
                            Label("Worker model", systemImage: "person.2")
                        }
                    }
                }

                if !viewModel.discoveredTypeScriptPlugins.isEmpty {
                    typeScriptPluginSection(draft: draft)
                }

                sectionCard(
                    title: "Included Capabilities",
                    subtitle: "The saved list is explicit: everything outside Included is excluded."
                ) {
                    Picker("Capability", selection: $capabilityKind) {
                        ForEach(CapabilityKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)

                    capabilityComposer(option: option)
                }
            }
            .padding(28)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func typeScriptPluginSection(draft: UserDynamicProfile? = nil) -> some View {
        sectionCard(
            title: "TypeScript plugins",
            subtitle: "Installed extensions are discovered automatically and shown separately from TurboCode tools."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if !settings.agentTuning.experimental.thirdPartyPluginsEnabled {
                    Label(
                        "Enable third-party plugins in Settings > Agents to load these tools.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                ForEach(viewModel.discoveredTypeScriptPlugins, id: \.manifest.id) { plugin in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(plugin.manifest.tools, id: \.name) { tool in
                                let toolID = TypeScriptPluginToolID(
                                    pluginID: plugin.manifest.id,
                                    toolName: tool.name
                                )
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "wrench.and.screwdriver")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tool.name)
                                            .font(.callout.weight(.medium))
                                        Text(tool.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "info.circle")
                                        .foregroundStyle(.secondary)
                                        .help(
                                            "\(tool.name)\n"
                                                + "\(tool.description)\n"
                                                + "ID: \(toolID.rawValue)"
                                        )
                                    Text(pluginToolStatus(toolID, draft: draft))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                                .help("\(tool.name): \(tool.description)")
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack(spacing: 8) {
                            Label(plugin.manifest.name, systemImage: "puzzlepiece.extension")
                                .font(.callout.weight(.semibold))
                            Text("v\(plugin.manifest.version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                                .help(
                                    "\(plugin.manifest.name)\n"
                                        + "ID: \(plugin.manifest.id)\n"
                                        + "Version: \(plugin.manifest.version)"
                                )
                            Spacer()
                            Text("\(plugin.manifest.tools.count) \(plugin.manifest.tools.count == 1 ? "tool" : "tools")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help("\(plugin.manifest.name) (\(plugin.manifest.id))\n\(plugin.manifest.tools.count) available tools")
                }
            }
        }
    }

    private func pluginToolStatus(
        _ id: TypeScriptPluginToolID,
        draft: UserDynamicProfile?
    ) -> String {
        if !settings.agentTuning.experimental.thirdPartyPluginsEnabled {
            return "Off"
        }
        guard let draft else { return "Available" }
        if draft.pluginToolIDs.isEmpty || draft.resolvedPluginToolIDs.contains(id) {
            return "Available"
        }
        return "Excluded"
    }

    /// Progressive disclosure keeps the common "all worker tools" path quiet,
    /// while the explicit allowlist remains discoverable beside the worker it
    /// controls. This avoids mixing coordinator and worker capabilities in the
    /// main Included Capabilities editor.
    @ViewBuilder
    private func workerToolDisclosure(draft: UserDynamicProfile) -> some View {
        let workerID = draft.resolvedWorkerModelID(
            fallback: ProfileBaseModelID.llama.rawValue
        )
        if let plan = viewModel.workerToolPlan(
            workerModelID: workerID,
            settings: settings
        ) {
            let defaultIDs = plan.registeredIDs
            let selectedIDs = draft.resolvedWorkerToolIDs ?? defaultIDs
            // Count only tools currently usable by this worker; unavailable
            // rows remain visible so the reason is discoverable inline.
            let selectedCount = selectedIDs.intersection(defaultIDs).count
            let usesAllTools = draft.workerToolIDs == nil

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Text("By default, the worker receives its complete supported tool set. Customize this only when the task needs a smaller surface.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle(
                        "Use all worker tools",
                        isOn: workerUsesAllToolsBinding(
                            defaultIDs: defaultIDs
                        )
                    )
                    .toggleStyle(.checkbox)

                    if !usesAllTools {
                        Divider()
                        Text("Selected tools")
                            .font(.subheadline.weight(.semibold))

                        ForEach(ToolCapabilityCategory.allCases, id: \.self) { category in
                            let assignments = plan.assignments.filter {
                                ModelToolCatalog.descriptor(for: $0.id).category == category
                            }
                            if !assignments.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(category.rawValue)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    ForEach(assignments) { assignment in
                                        workerToolToggle(
                                            assignment,
                                            defaultIDs: defaultIDs
                                        )
                                    }
                                }
                            }
                        }

                        if selectedCount == 0 {
                            Label(
                                "No tools selected. The worker can return text but cannot inspect or change the workspace.",
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Label("Worker tools", systemImage: "wrench.and.screwdriver")
                    Spacer()
                    Text(usesAllTools ? "All tools" : "\(selectedCount) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 10)
        }
    }

    private func workerUsesAllToolsBinding(
        defaultIDs: Set<ToolCapabilityID>
    ) -> Binding<Bool> {
        Binding(
            get: { viewModel.draft?.workerToolIDs == nil },
            set: { usesAllTools in
                viewModel.updateDraft { value in
                    value.workerToolIDs = usesAllTools
                        ? nil
                        : defaultIDs.map(\.rawValue).sorted()
                }
            }
        )
    }

    @ViewBuilder
    private func workerToolToggle(
        _ assignment: ModelToolAssignment,
        defaultIDs: Set<ToolCapabilityID>
    ) -> some View {
        let descriptor = ModelToolCatalog.descriptor(for: assignment.id)
        Toggle(
            isOn: workerToolBinding(
                id: assignment.id,
                defaultIDs: defaultIDs
            )
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.name)
                Text(assignment.unavailableReason ?? descriptor.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!assignment.isRegistered)
        .opacity(assignment.isRegistered ? 1 : 0.58)
    }

    private func workerToolBinding(
        id: ToolCapabilityID,
        defaultIDs: Set<ToolCapabilityID>
    ) -> Binding<Bool> {
        Binding(
            get: {
                viewModel.draft?.resolvedWorkerToolIDs?.contains(id)
                    ?? defaultIDs.contains(id)
            },
            set: { included in
                viewModel.updateDraft { value in
                    var selected = value.resolvedWorkerToolIDs ?? defaultIDs
                    if included {
                        selected.insert(id)
                    } else {
                        selected.remove(id)
                    }
                    value.workerToolIDs = selected == defaultIDs
                        ? nil
                        : selected.map(\.rawValue).sorted()
                }
            }
        )
    }

    @ViewBuilder
    private func capabilityComposer(option: ProfileModelOption) -> some View {
        let search = viewModel.capabilitySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(alignment: .top, spacing: 12) {
            capabilityColumn(title: "Available", targeted: availableDropTargeted) {
                TextField("Filter \(capabilityKind.rawValue.lowercased())", text: $viewModel.capabilitySearch)
                    .textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if capabilityKind == .tools {
                            ForEach(availableTools(option: option, search: search)) { tool in
                                availableToolRow(tool, option: option)
                            }
                        } else {
                            ForEach(availableSkills(search: search)) { skill in
                                availableSkillRow(skill)
                            }
                        }
                    }
                }
            }
            .dropDestination(for: String.self) { values, _ in
                remove(values: values)
            } isTargeted: { availableDropTargeted = $0 }

            capabilityColumn(title: "Included", targeted: includedDropTargeted) {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if capabilityKind == .tools {
                            ForEach(includedTools()) { tool in includedToolRow(tool, option: option) }
                            ForEach(missingToolIDs(), id: \.self) { toolID in
                                missingCapabilityRow(toolID) {
                                    if let id = ToolCapabilityID(rawValue: toolID) {
                                        viewModel.setTool(id, included: false)
                                    } else {
                                        viewModel.updateDraft { $0.toolIDs.removeAll { $0 == toolID } }
                                    }
                                }
                            }
                        } else {
                            ForEach(includedSkills()) { skill in includedSkillRow(skill) }
                            ForEach(missingSkillIDs(), id: \.self) { skillID in
                                missingCapabilityRow(skillID) {
                                    viewModel.setSkill(skillID, included: false)
                                }
                            }
                        }
                        if includedCount == 0 {
                            ContentUnavailableView(
                                "No \(capabilityKind.rawValue)",
                                systemImage: "arrow.left.arrow.right",
                                description: Text("Drag items here or use the add buttons.")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.top, 36)
                        }
                    }
                }
            }
            .dropDestination(for: String.self) { values, _ in
                include(values: values, option: option)
            } isTargeted: { includedDropTargeted = $0 }
        }
        .frame(height: 350)
        .overlay {
            if let hoveredTool {
                ToolInformationCard(
                    tool: hoveredTool.tool,
                    availability: hoveredTool.availability,
                    isAvailable: hoveredTool.isAvailable
                )
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: hoveredTool.column == .available ? .topTrailing : .topLeading
                )
                .padding(.horizontal, 14)
                .padding(.top, 42)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                .allowsHitTesting(false)
                .zIndex(20)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredTool)
    }

    private func availableTools(option: ProfileModelOption, search: String) -> [ToolCapabilityDescriptor] {
        ModelToolCatalog.descriptors.filter {
            // Loading skills is derived from the selected skill set and legacy
            // delegation is not authorable. Structured delegate_task remains
            // visible because it is a supported override capability.
            $0.id != .loadSkill
                && $0.id != .callPowerfulModel
                && !viewModel.containsTool($0.id)
                && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                    || $0.id.rawValue.localizedCaseInsensitiveContains(search))
        }
    }

    private func includedTools() -> [ToolCapabilityDescriptor] {
        ModelToolCatalog.descriptors.filter { viewModel.containsTool($0.id) }
    }

    private func availableSkills(search: String) -> [TurboCodeSkillDefinition] {
        viewModel.installedSkills.filter {
            !viewModel.containsSkill($0.name)
                && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                    || $0.description.localizedCaseInsensitiveContains(search))
        }
    }

    private func includedSkills() -> [TurboCodeSkillDefinition] {
        viewModel.installedSkills.filter { viewModel.containsSkill($0.name) }
    }

    private func missingToolIDs() -> [String] {
        let known = Set(ModelToolCatalog.descriptors.map { $0.id.rawValue })
        return viewModel.draft?.toolIDs.filter { !known.contains($0) } ?? []
    }

    private func missingSkillIDs() -> [String] {
        let installed = Set(viewModel.installedSkills.map(\.name))
        return viewModel.draft?.skillIDs.filter { !installed.contains($0) } ?? []
    }

    private var includedCount: Int {
        capabilityKind == .tools
            ? (viewModel.draft?.toolIDs.count ?? 0)
            : (viewModel.draft?.skillIDs.count ?? 0)
    }

    private func availableToolRow(_ tool: ToolCapabilityDescriptor, option: ProfileModelOption) -> some View {
        let compatible = option.compatibleToolIDs.contains(tool.id)
        return capabilityRow(
            icon: tool.systemImage,
            title: tool.name,
            subtitle: compatible
                ? (tool.id == .delegateTask
                    ? "Adds a worker picker"
                    : tool.id.runtimeName)
                : "Unavailable for this model",
            compatible: compatible,
            actionIcon: compatible ? "plus.circle" : nil
        ) {
            viewModel.setTool(tool.id, included: true)
        }
        .draggable(tool.id.rawValue)
        .opacity(compatible ? 1 : 0.55)
        .onHover { hovering in
            updateToolHover(
                tool,
                availability: compatible
                    ? "Available for \(option.id.displayName)"
                    : "Unavailable for \(option.id.displayName)",
                isAvailable: compatible,
                column: .available,
                hovering: hovering
            )
        }
    }

    private func includedToolRow(_ tool: ToolCapabilityDescriptor, option: ProfileModelOption) -> some View {
        let compatible = option.compatibleToolIDs.contains(tool.id)
        return capabilityRow(
            icon: compatible ? tool.systemImage : "exclamationmark.triangle",
            title: tool.name,
            subtitle: compatible ? tool.id.runtimeName : "Not supported by \(option.id.displayName)",
            compatible: compatible,
            actionIcon: "minus.circle"
        ) {
            viewModel.setTool(tool.id, included: false)
        }
        .draggable(tool.id.rawValue)
        .onHover { hovering in
            updateToolHover(
                tool,
                availability: compatible
                    ? "Included for \(option.id.displayName)"
                    : "Not supported by \(option.id.displayName)",
                isAvailable: compatible,
                column: .included,
                hovering: hovering
            )
        }
    }

    private func availableSkillRow(_ skill: TurboCodeSkillDefinition) -> some View {
        capabilityRow(
            icon: "doc.text",
            title: skill.name,
            subtitle: skill.description,
            compatible: true,
            actionIcon: "plus.circle"
        ) { viewModel.setSkill(skill.name, included: true) }
        .draggable(skill.name)
    }

    private func includedSkillRow(_ skill: TurboCodeSkillDefinition) -> some View {
        capabilityRow(
            icon: "doc.text",
            title: skill.name,
            subtitle: skill.description,
            compatible: true,
            actionIcon: "minus.circle"
        ) { viewModel.setSkill(skill.name, included: false) }
        .draggable(skill.name)
    }

    private func missingCapabilityRow(_ id: String, remove: @escaping () -> Void) -> some View {
        capabilityRow(
            icon: "exclamationmark.triangle",
            title: id,
            subtitle: "Not currently installed",
            compatible: false,
            actionIcon: "minus.circle",
            action: remove
        )
    }

    private func capabilityRow(
        icon: String,
        title: String,
        subtitle: String,
        compatible: Bool,
        actionIcon: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(compatible ? Color.secondary : Color.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Text(subtitle).font(AppTypography.metadata).foregroundStyle(.tertiary).lineLimit(2)
            }
            Spacer()
            if let actionIcon {
                Button(action: action) { Image(systemName: actionIcon) }
                    .buttonStyle(.borderless)
                    .disabled(!compatible && actionIcon == "plus.circle")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }

    private func capabilityColumn<Content: View>(
        title: String,
        targeted: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            targeted ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(targeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private func include(values: [String], option: ProfileModelOption) -> Bool {
        var changed = false
        if capabilityKind == .tools {
            for value in values {
                guard let id = ToolCapabilityID(rawValue: value), option.compatibleToolIDs.contains(id) else { continue }
                viewModel.setTool(id, included: true)
                changed = true
            }
        } else {
            let names = Set(viewModel.installedSkills.map(\.name))
            for value in values where names.contains(value) {
                viewModel.setSkill(value, included: true)
                changed = true
            }
        }
        return changed
    }

    private func remove(values: [String]) -> Bool {
        var changed = false
        if capabilityKind == .tools {
            for value in values {
                guard let id = ToolCapabilityID(rawValue: value), viewModel.containsTool(id) else { continue }
                viewModel.setTool(id, included: false)
                changed = true
            }
        } else {
            for value in values where viewModel.containsSkill(value) {
                viewModel.setSkill(value, included: false)
                changed = true
            }
        }
        return changed
    }

    private func sectionCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(16)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
    }

    private func infoBanner(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }

    private func capabilityBadge(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11.5, weight: .medium))
                Text(subtitle).font(AppTypography.metadata).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(9)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private var selectionBinding: Binding<ProfileLibrarySelection?> {
        Binding(
            get: { viewModel.selection },
            set: { if let value = $0 { viewModel.select(value) } }
        )
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { viewModel.draft?.name ?? "" },
            set: { value in viewModel.updateDraft { $0.name = value } }
        )
    }

    private var summaryBinding: Binding<String> {
        Binding(
            get: { viewModel.draft?.summary ?? "" },
            set: { value in viewModel.updateDraft { $0.summary = value } }
        )
    }

    private var baseModelBinding: Binding<ProfileBaseModelID> {
        Binding(
            get: { viewModel.draft?.baseModelID ?? .onDevice },
            set: { value in
                let update = {
                    viewModel.updateDraft {
                        $0.baseModelID = value
                        if value == .deepseek {
                            $0.greedyMode = false
                        } else if value == .codex {
                            // Seed a reproducible route when the App Server
                            // catalog is known; otherwise Default remains a
                            // valid login-independent fallback.
                            $0.codexModelID =
                                $0.codexModelID
                                    ?? chatStore.codexPreferredModel?.id
                            $0.codexReasoningEffort =
                                $0.codexReasoningEffort
                                    ?? chatStore.codexReasoningEffort
                        }
                    }
                }
                if reduceMotion {
                    update()
                } else {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        update()
                    }
                }
            }
        )
    }

    private var greedyModeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.draft?.greedyMode ?? false },
            set: { value in viewModel.updateDraft { $0.greedyMode = value } }
        )
    }

    private var workerModelBinding: Binding<String> {
        Binding(
            get: {
                viewModel.draft?.resolvedWorkerModelID(
                    fallback: ProfileBaseModelID.llama.rawValue
                ) ?? ProfileBaseModelID.llama.rawValue
            },
            set: { value in
                viewModel.updateDraft { $0.workerModelID = value }
            }
        )
    }

    private var codexModelBinding: Binding<String> {
        Binding(
            get: { viewModel.draft?.codexModelID ?? "" },
            set: { value in
                viewModel.updateDraft {
                    $0.codexModelID = value.isEmpty ? nil : value
                    guard let effort = $0.codexReasoningEffort else { return }
                    if !codexReasoningOptions(for: $0.codexModelID).contains(
                        where: { $0.reasoningEffort == effort }
                    ) {
                        // A model change cannot retain an effort that the App
                        // Server says is unsupported.
                        $0.codexReasoningEffort = nil
                    }
                }
            }
        )
    }

    private var codexReasoningBinding: Binding<String> {
        Binding(
            get: {
                viewModel.draft?.codexReasoningEffort?.rawValue ?? ""
            },
            set: { value in
                viewModel.updateDraft {
                    $0.codexReasoningEffort = value.isEmpty
                        ? nil
                        : CodexReasoningEffort(rawValue: value)
                }
            }
        )
    }

    private func codexReasoningOptions(
        for modelID: String?
    ) -> [CodexReasoningOption] {
        chatStore.codexModels.first(where: { $0.id == modelID })?
            .supportedReasoningEfforts
            ?? chatStore.codexReasoningOptions
    }

    /// An unloaded catalog is not an error because authentication can happen
    /// after selection. Once loaded, stale explicit values fail visibly instead
    /// of silently running a different profile configuration.
    private func codexConfigurationIsAvailable(
        for profile: UserDynamicProfile
    ) -> Bool {
        guard profile.baseModelID == .codex,
              !chatStore.codexModels.isEmpty else {
            return true
        }
        let selectedModel: CodexModelDescriptor?
        if let modelID = profile.codexModelID {
            selectedModel = chatStore.codexModels.first {
                $0.id == modelID
            }
            guard selectedModel != nil else { return false }
        } else {
            selectedModel = chatStore.codexPreferredModel
        }
        guard let effort = profile.codexReasoningEffort else {
            return true
        }
        return selectedModel?.supportedReasoningEfforts.contains {
            $0.reasoningEffort == effort
        } == true
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private func revealSkillsDirectory() {
        NSWorkspace.shared.open(TurboCodeConfig.shared.skillsDirectoryURL)
    }

    private func updateToolHover(
        _ tool: ToolCapabilityDescriptor,
        availability: String,
        isAvailable: Bool,
        column: ToolHoverColumn,
        hovering: Bool
    ) {
        pendingToolHover?.cancel()

        guard hovering else {
            if hoveredTool?.tool.id == tool.id {
                hoveredTool = nil
            }
            return
        }

        let presentation = ToolHoverPresentation(
            tool: tool,
            availability: availability,
            isAvailable: isAvailable,
            column: column
        )
        pendingToolHover = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            hoveredTool = presentation
        }
    }
}

private enum ToolHoverColumn: Equatable {
    case available
    case included
}

private struct ToolHoverPresentation: Equatable {
    let tool: ToolCapabilityDescriptor
    let availability: String
    let isAvailable: Bool
    let column: ToolHoverColumn
}

private extension View {
    func toolInformationHoverCard(
        _ tool: ToolCapabilityDescriptor,
        availability: String,
        isAvailable: Bool
    ) -> some View {
        modifier(
            ToolInformationHoverCardModifier(
                tool: tool,
                availability: availability,
                isAvailable: isAvailable
            )
        )
    }
}

private struct ToolInformationHoverCardModifier: ViewModifier {
    let tool: ToolCapabilityDescriptor
    let availability: String
    let isAvailable: Bool

    @State private var isPresented = false
    @State private var pendingPresentation: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                pendingPresentation?.cancel()
                if hovering {
                    pendingPresentation = Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled else { return }
                        isPresented = true
                    }
                } else {
                    isPresented = false
                }
            }
            .onDisappear { pendingPresentation?.cancel() }
            .overlay(alignment: .topTrailing) {
                if isPresented {
                    ToolInformationCard(
                        tool: tool,
                        availability: availability,
                        isAvailable: isAvailable
                    )
                        .offset(x: -8, y: 34)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
                        .allowsHitTesting(false)
                }
            }
            .zIndex(isPresented ? 10 : 0)
            .animation(.easeOut(duration: 0.12), value: isPresented)
    }
}

private struct ToolInformationCard: View {
    let tool: ToolCapabilityDescriptor
    let availability: String
    let isAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tool.name, systemImage: tool.systemImage)
                .font(.headline)

            Text(tool.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                metadataRow("Tool call", value: tool.id.runtimeName, monospaced: true)
                metadataRow("Category", value: tool.category.rawValue)
                metadataRow(
                    "Interface",
                    value: tool.hasNativePresentation ? "Native result view" : "Text result"
                )
            }

            Label(
                availability,
                systemImage: isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(isAvailable ? Color.green : Color.orange)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }

    @ViewBuilder
    private func metadataRow(_ title: String, value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct NewDynamicProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let modelOptions: [ProfileModelOption]
    let delegationOptions: [ProfileModelOption]
    let workerOptions: [ProfileModelOption]
    let codexModels: [CodexModelDescriptor]
    let codexDefaultReasoningOptions: [CodexReasoningOption]
    let onCreate: (
        String,
        String,
        ProfileBaseModelID,
        String?,
        String?,
        CodexReasoningEffort?,
        Bool,
        Bool
    ) -> Bool
    @State private var name = ""
    @State private var summary = ""
    @State private var baseModelID: ProfileBaseModelID
    @State private var workerModelID = ProfileBaseModelID.llama.rawValue
    @State private var codexModelID: String
    @State private var codexReasoningEffort: String
    @State private var delegationEnabled: Bool
    @State private var copyDefaults = false
    @FocusState private var nameFocused: Bool

    init(
        initialBaseModel: ProfileBaseModelID,
        initialDelegationEnabled: Bool,
        initialCopyDefaults: Bool,
        modelOptions: [ProfileModelOption],
        delegationOptions: [ProfileModelOption],
        workerOptions: [ProfileModelOption],
        codexModels: [CodexModelDescriptor],
        codexDefaultReasoningOptions: [CodexReasoningOption],
        initialCodexModelID: String?,
        initialCodexReasoningEffort: CodexReasoningEffort?,
        onCreate: @escaping (
            String,
            String,
            ProfileBaseModelID,
            String?,
            String?,
            CodexReasoningEffort?,
            Bool,
            Bool
        ) -> Bool
    ) {
        self.modelOptions = modelOptions
        self.delegationOptions = delegationOptions
        self.workerOptions = workerOptions
        self.codexModels = codexModels
        self.codexDefaultReasoningOptions = codexDefaultReasoningOptions
        self.onCreate = onCreate
        _baseModelID = State(initialValue: initialBaseModel)
        _delegationEnabled = State(initialValue: initialDelegationEnabled)
        _copyDefaults = State(initialValue: initialCopyDefaults)
        _codexModelID = State(initialValue: initialCodexModelID ?? "")
        let initialModel = codexModels.first {
            $0.id == initialCodexModelID
        }
        let initialEffort = initialCodexReasoningEffort.flatMap { effort in
            initialModel?.supportedReasoningEfforts.contains(where: {
                $0.reasoningEffort == effort
            }) == false ? initialModel?.defaultReasoningEffort : effort
        }
        _codexReasoningEffort = State(
            initialValue: initialEffort?.rawValue ?? ""
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Profile").font(.system(size: 21, weight: .semibold))
                Text("Choose what the profile does. Advanced capabilities can be composed next.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 13) {
                GridRow {
                    Text("Name")
                    TextField("GitHub PR Assistant", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                }
                GridRow {
                    Text("Description")
                    TextField("Focused purpose", text: $summary)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Model")
                    Picker("Model", selection: $baseModelID) {
                        ForEach(modelOptions) { option in
                                Label(option.id.displayName, systemImage: option.id.systemImage)
                                    .tag(option.id)
                                .disabled(
                                    !option.isAvailable
                                        || (delegationEnabled
                                            && !delegationOptions.contains(where: {
                                                $0.id == option.id
                                            }))
                                )
                        }
                    }
                    .labelsHidden()
                }
                if baseModelID == .codex {
                    GridRow {
                        Text("Codex model")
                        Picker("Codex model", selection: codexModelBinding) {
                            Text("Codex Default").tag("")
                            if !codexModelID.isEmpty,
                               !codexModels.contains(where: { $0.id == codexModelID }) {
                                Text(codexModelID).tag(codexModelID)
                            }
                            ForEach(codexModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Reasoning")
                        Picker("Reasoning", selection: codexReasoningBinding) {
                            Text("Model Default").tag("")
                            ForEach(codexReasoningOptions, id: \.reasoningEffort.rawValue) { option in
                                Text(option.reasoningEffort.displayName)
                                    .tag(option.reasoningEffort.rawValue)
                            }
                        }
                        .labelsHidden()
                    }
                }
                if delegationOptions.contains(where: { $0.id == baseModelID }) {
                    GridRow {
                        Text("Delegation")
                        Toggle("Delegate implementation tasks", isOn: $delegationEnabled)
                            .toggleStyle(.checkbox)
                    }
                    if delegationEnabled {
                        GridRow {
                            Text("Worker")
                            Picker("Worker", selection: $workerModelID) {
                                ForEach(workerOptions) { option in
                                    Label(option.id.displayName, systemImage: option.id.systemImage)
                                        .tag(option.id.rawValue)
                                        .disabled(!option.isAvailable)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }
                GridRow {
                    Text("Start with")
                    Picker("Starting point", selection: $copyDefaults) {
                        Text("Empty").tag(false)
                        Text("Model Defaults").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            Text(delegationEnabled
                 ? "Delegate Task will be included with \(baseModelID.displayName) and use the selected worker."
                 : (copyDefaults
                    ? "Copies the model's current tools and installed skills into an explicit list."
                    : "Starts with no tools or skills, ideal for a focused workflow."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    if onCreate(
                        name,
                        summary,
                        baseModelID,
                        delegationEnabled ? workerModelID : nil,
                        baseModelID == .codex && !codexModelID.isEmpty
                            ? codexModelID
                            : nil,
                        baseModelID == .codex
                            ? CodexReasoningEffort(
                                rawValue: codexReasoningEffort
                            )
                            : nil,
                        delegationEnabled,
                        copyDefaults
                    ) {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !selectionIsAvailable
                )
            }
        }
        .padding(24)
        .frame(width: 510)
        .onAppear { nameFocused = true }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.16),
            value: delegationEnabled
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.16),
            value: baseModelID
        )
    }

    private var codexReasoningOptions: [CodexReasoningOption] {
        codexModels.first(where: { $0.id == codexModelID })?
            .supportedReasoningEfforts
            ?? codexDefaultReasoningOptions
    }

    private var codexReasoningBinding: Binding<String> {
        Binding(
            get: { codexReasoningEffort },
            set: { codexReasoningEffort = $0 }
        )
    }

    private var codexModelBinding: Binding<String> {
        Binding(
            get: { codexModelID },
            set: { value in
                codexModelID = value
                guard let effort = CodexReasoningEffort(
                    rawValue: codexReasoningEffort
                ) else { return }
                if !codexReasoningOptions.contains(where: {
                    $0.reasoningEffort == effort
                }) {
                    codexReasoningEffort = ""
                }
            }
        )
    }

    /// Prevents saving a profile whose selected delegation dependencies are
    /// unavailable while leaving all configuration choices visible.
    private var selectionIsAvailable: Bool {
        if delegationEnabled {
            return delegationOptions.first(where: {
                $0.id == baseModelID
            })?.isAvailable == true
                && workerOptions.first(where: {
                    $0.id.rawValue == workerModelID
                })?.isAvailable == true
        }
        return modelOptions.first(where: {
            $0.id == baseModelID
        })?.isAvailable == true
    }
}
