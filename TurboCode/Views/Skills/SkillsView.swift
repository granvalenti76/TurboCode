import AppKit
import SwiftUI

struct SkillsView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel = SkillsViewModel()
    @State private var newProfilePresented = false
    @State private var suggestedBaseModel: ProfileBaseModelID = .onDevice
    @State private var suggestedExecutionRole: ProfileExecutionRole = .direct
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
                suggestedExecutionRole = requestedRole
                suggestedBaseModel = requestedRole == .coordinatorWorker
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
                initialExecutionRole: suggestedExecutionRole,
                initialCopyDefaults: suggestedCopyDefaults,
                modelOptions: viewModel.modelOptions(settings: settings),
                coordinatorOptions: viewModel.coordinatorOptions(settings: settings),
                workerOptions: viewModel.workerOptions(settings: settings)
            ) { name, summary, model, worker, role, copyDefaults in
                viewModel.create(
                    name: name,
                    summary: summary,
                    baseModelID: model,
                    workerModelID: worker,
                    executionRole: role,
                    copyDefaults: copyDefaults,
                    settings: settings
                )
            }
        }
        .alert("Delete Profile?", isPresented: $deleteConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { viewModel.deleteSelected() }
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
                    suggestedExecutionRole = .direct
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
                            Button("Use Profile") { chatStore.selectDynamicProfile(profile.id) }
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
                    chatStore.reloadSkills()
                    chatStore.reloadDynamicProfiles()
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
                        chatStore.selectBuiltInProfile(modelID)
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
                            capabilityBadge(icon: tool.systemImage, title: tool.name, subtitle: tool.id.rawValue)
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
                draft.executionRole == .direct
                    || workerOption?.isAvailable == true
            )
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
                    Button("Save") { viewModel.save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!viewModel.canSave || chatStore.busy)
                    Button("Use Profile") {
                        if !viewModel.isDirty || viewModel.save() {
                            chatStore.selectDynamicProfile(draft.id)
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
                } else if draft.executionRole == .coordinatorWorker,
                          workerOption?.isAvailable != true {
                    infoBanner(
                        icon: "exclamationmark.triangle",
                        title: "Worker unavailable",
                        text: "Enable and configure the selected worker before using this coordinator profile."
                    )
                }

                sectionCard(
                    title: "Execution",
                    subtitle: "Choose the profile’s responsibility before configuring advanced capabilities."
                ) {
                    Picker("Execution role", selection: executionRoleBinding) {
                        ForEach(ProfileExecutionRole.allCases) { role in
                            Text(role.displayName).tag(role)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 420)

                    Text(draft.executionRole.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)

                    if draft.executionRole == .coordinatorWorker {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                            GridRow {
                                Text("Coordinator").foregroundStyle(.secondary)
                                Picker("Coordinator", selection: baseModelBinding) {
                                    ForEach(viewModel.coordinatorOptions(settings: settings)) { model in
                                        Label(model.id.displayName, systemImage: model.id.systemImage)
                                            .tag(model.id)
                                            .disabled(!model.isAvailable)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 280, alignment: .leading)
                            }
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

                        infoBanner(
                            icon: "arrow.triangle.branch",
                            title: "Structured delegation",
                            text: "\(draft.baseModelID.displayName) plans the request. Delegate Task sends a bounded goal, acceptance criteria, and verification request to the selected worker."
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
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
                        if draft.executionRole == .direct {
                            GridRow {
                                Text("Model").foregroundStyle(.secondary)
                                HStack(spacing: 14) {
                                    Picker("Model", selection: baseModelBinding) {
                                        ForEach(viewModel.modelOptions(settings: settings)) { model in
                                            Label(model.id.displayName, systemImage: model.id.systemImage)
                                                .tag(model.id)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: 280, alignment: .leading)
                                    Toggle("Greedy mode", isOn: greedyModeBinding)
                                        .toggleStyle(.checkbox)
                                        .disabled(draft.baseModelID == .deepseek)
                                    Text(draft.baseModelID == .deepseek
                                            ? "Unavailable with DeepSeek Thinking."
                                            : "Always pick the most likely token.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
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
            // Delegation is owned by the Execution picker; hiding it here keeps
            // the drag composer focused on optional advanced capabilities.
            $0.id != .delegateTask
                && $0.id != .loadSkill
                && $0.id != .callPowerfulModel
                && !viewModel.containsTool($0.id)
                && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                    || $0.id.rawValue.localizedCaseInsensitiveContains(search))
        }
    }

    private func includedTools() -> [ToolCapabilityDescriptor] {
        ModelToolCatalog.descriptors.filter {
            $0.id != .delegateTask && viewModel.containsTool($0.id)
        }
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
            ? (viewModel.draft?.toolIDs.filter {
                $0 != ToolCapabilityID.delegateTask.rawValue
            }.count ?? 0)
            : (viewModel.draft?.skillIDs.count ?? 0)
    }

    private func availableToolRow(_ tool: ToolCapabilityDescriptor, option: ProfileModelOption) -> some View {
        let compatible = option.compatibleToolIDs.contains(tool.id)
        return capabilityRow(
            icon: tool.systemImage,
            title: tool.name,
            subtitle: compatible ? tool.id.rawValue : "Unavailable for this model",
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
            subtitle: compatible ? tool.id.rawValue : "Not supported by \(option.id.displayName)",
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

    private var executionRoleBinding: Binding<ProfileExecutionRole> {
        Binding(
            get: { viewModel.draft?.executionRole ?? .direct },
            set: { role in
                if reduceMotion {
                    viewModel.setExecutionRole(role)
                } else {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        viewModel.setExecutionRole(role)
                    }
                }
            }
        )
    }

    private var baseModelBinding: Binding<ProfileBaseModelID> {
        Binding(
            get: { viewModel.draft?.baseModelID ?? .onDevice },
            set: { value in
                viewModel.updateDraft {
                    $0.baseModelID = value
                    if value == .deepseek {
                        $0.greedyMode = false
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
                metadataRow("Tool call", value: tool.id.rawValue, monospaced: true)
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
    let coordinatorOptions: [ProfileModelOption]
    let workerOptions: [ProfileModelOption]
    let onCreate: (
        String,
        String,
        ProfileBaseModelID,
        String?,
        ProfileExecutionRole,
        Bool
    ) -> Bool
    @State private var name = ""
    @State private var summary = ""
    @State private var baseModelID: ProfileBaseModelID
    @State private var workerModelID = ProfileBaseModelID.llama.rawValue
    @State private var executionRole: ProfileExecutionRole
    @State private var copyDefaults = false
    @FocusState private var nameFocused: Bool

    init(
        initialBaseModel: ProfileBaseModelID,
        initialExecutionRole: ProfileExecutionRole,
        initialCopyDefaults: Bool,
        modelOptions: [ProfileModelOption],
        coordinatorOptions: [ProfileModelOption],
        workerOptions: [ProfileModelOption],
        onCreate: @escaping (
            String,
            String,
            ProfileBaseModelID,
            String?,
            ProfileExecutionRole,
            Bool
        ) -> Bool
    ) {
        self.modelOptions = modelOptions
        self.coordinatorOptions = coordinatorOptions
        self.workerOptions = workerOptions
        self.onCreate = onCreate
        _baseModelID = State(initialValue: initialBaseModel)
        _executionRole = State(initialValue: initialExecutionRole)
        _copyDefaults = State(initialValue: initialCopyDefaults)
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
                    Text("Execution")
                    Picker("Execution", selection: executionRoleBinding) {
                        ForEach(ProfileExecutionRole.allCases) { role in
                            Text(role.displayName).tag(role)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                GridRow {
                    Text(executionRole == .coordinatorWorker ? "Coordinator" : "Model")
                    if executionRole == .coordinatorWorker {
                        Picker("Coordinator", selection: $baseModelID) {
                            ForEach(coordinatorOptions) { option in
                                Label(option.id.displayName, systemImage: option.id.systemImage)
                                    .tag(option.id)
                                    .disabled(!option.isAvailable)
                            }
                        }
                        .labelsHidden()
                        .transition(.opacity)
                    } else {
                        Picker("Model", selection: $baseModelID) {
                            ForEach(modelOptions) { option in
                                Text(option.id.displayName).tag(option.id)
                            }
                        }
                        .labelsHidden()
                        .transition(.opacity)
                    }
                }
                if executionRole == .coordinatorWorker {
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

            Text(executionRole == .coordinatorWorker
                 ? "\(baseModelID.displayName) will coordinate and Delegate Task will be managed automatically for the selected worker."
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
                        executionRole == .coordinatorWorker ? workerModelID : nil,
                        executionRole,
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
            value: executionRole
        )
    }

    private var executionRoleBinding: Binding<ProfileExecutionRole> {
        Binding(
            get: { executionRole },
            set: { role in
                executionRole = role
                if role == .coordinatorWorker {
                    // Keep the visible form consistent with the runtime
                    // invariant before the user confirms creation.
                    baseModelID = .deepseek
                }
            }
        )
    }

    /// Prevents saving a route that cannot be run while still leaving every
    /// configured choice visible in its contextual picker.
    private var selectionIsAvailable: Bool {
        if executionRole == .coordinatorWorker {
            return coordinatorOptions.first(where: {
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
