import AppKit
import SwiftUI

struct SkillsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var viewModel = SkillsViewModel()
    @State private var deleteConfirmationPresented = false
    @State private var profileDropIsTargeted = false
    @State private var availableDropIsTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            skillList
                .frame(width: 260)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            settings.reloadRemoteModels()
            viewModel.reload()
        }
        .alert("Unsaved Changes", isPresented: discardAlertPresented) {
            Button("Cancel", role: .cancel) { viewModel.cancelDiscard() }
            Button("Discard", role: .destructive) { viewModel.confirmDiscard() }
        } message: {
            Text(viewModel.confirmationMessage ?? "Discard unsaved changes?")
        }
        .alert("Delete Skill?", isPresented: $deleteConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { viewModel.deleteSelected() }
        } message: {
            Text("This permanently removes the skill directory from ~/.turbocode/SKILLS.")
        }
        .alert("Skill Error", isPresented: errorAlertPresented) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "The skill could not be updated.")
        }
    }

    private var skillList: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skills")
                        .font(.system(size: 19, weight: .semibold))
                    Text("\(viewModel.records.count) installed")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.requestNewSkill()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .help("New Skill")
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 10)

            List(selection: skillSelection) {
                ForEach(viewModel.filteredRecords) { record in
                    skillRow(record)
                        .tag(record.id)
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $viewModel.searchText, placement: .sidebar, prompt: "Search skills")

            Divider()
            HStack {
                Text("~/.turbocode/SKILLS")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    viewModel.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload Skills")
            }
            .padding(10)
        }
        .background(.quaternary.opacity(0.08))
    }

    private func skillRow(_ record: SkillEditorRecord) -> some View {
        HStack(spacing: 9) {
            Image(systemName: record.definition == nil ? "exclamationmark.triangle" : "doc.text")
                .foregroundStyle(record.definition == nil ? .orange : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(record.description)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var editor: some View {
        if viewModel.draft != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    editorHeader
                    identitySection
                    instructionsSection
                    modelProfilesSection
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            ContentUnavailableView {
                Label("Select a Skill", systemImage: "doc.text")
            } description: {
                Text("Choose a valid skill or create a new one.")
            } actions: {
                Button("New Skill") { viewModel.requestNewSkill() }
            }
        }
    }

    private var editorHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.draft?.originalURL == nil ? "New Skill" : "Edit Skill")
                    .font(.system(size: 26, weight: .semibold))
                Text("A SKILL.md remains fully editable from Terminal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let url = viewModel.draft?.originalURL {
                Button {
                    reveal(url)
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .help("Reveal SKILL.md in Finder")
            }
            if viewModel.draft?.originalURL != nil, viewModel.draft?.isBuiltIn == false {
                Button(role: .destructive) {
                    deleteConfirmationPresented = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            Button("Revert") {
                viewModel.discardChanges()
            }
            .disabled(!viewModel.isDirty || viewModel.draft?.originalURL == nil)

            Button("Save") {
                viewModel.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canSave)
        }
    }

    private var identitySection: some View {
        sectionCard(title: "Identity", subtitle: "Used for discovery and /skill commands.") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Name")
                        .foregroundStyle(.secondary)
                    TextField("lowercase-kebab-name", text: nameBinding)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.draft?.isBuiltIn == true)
                }
                GridRow {
                    Text("Description")
                        .foregroundStyle(.secondary)
                    TextField("When should TurboCode activate this skill?", text: descriptionBinding)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .gridColumnAlignment(.leading)

            if let url = viewModel.draft?.originalURL {
                HStack(spacing: 7) {
                    Text(abbreviatedPath(url.path))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        copy(url.path)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy Path")
                }
            }
        }
    }

    private var instructionsSection: some View {
        sectionCard(title: "Instructions", subtitle: "Markdown loaded when the skill is activated.") {
            TextEditor(text: promptBinding)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 230)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
        }
    }

    private var modelProfilesSection: some View {
        let profiles = viewModel.modelProfiles(settings: settings)
        let selected = profiles.first(where: { $0.id == viewModel.selectedProfileID }) ?? profiles[0]
        return sectionCard(
            title: "Model Profiles",
            subtitle: "Inherit TurboCode defaults or compose a focused tool set for each model."
        ) {
            Picker("Model", selection: $viewModel.selectedProfileID) {
                ForEach(profiles) { profile in
                    Text(profile.id.displayName).tag(profile.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            profileEditor(selected)
                .id(selected.id)
                .transition(.opacity)
        }
    }

    private func profileEditor(_ profile: SkillModelProfileOption) -> some View {
        let isEnabled = viewModel.override(for: profile.id) != nil
        let profileOverride = viewModel.override(for: profile.id)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.id.displayName)
                        .font(.system(size: 15, weight: .semibold))
                    Text(profile.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(tierLabel(profile.tier))
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.3), in: Capsule())
            }

            Toggle("Customize this model", isOn: Binding(
                get: { viewModel.override(for: profile.id) != nil },
                set: { viewModel.setOverrideEnabled($0, for: profile) }
            ))

            if isEnabled, let profileOverride {
                Toggle("Start from the default tool set", isOn: Binding(
                    get: { viewModel.override(for: profile.id)?.inheritsDefaults ?? true },
                    set: { viewModel.setInheritsDefaults($0, for: profile) }
                ))

                Text(profileOverride.inheritsDefaults
                     ? "Default tools stay available. Tools added here extend the profile."
                     : "Only the tools added here will be requested by this skill.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                toolComposer(profile, profileOverride: profileOverride)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Text("Uses the default \(profile.id.displayName) profile with \(profile.defaultToolCount) tools.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: isEnabled)
    }

    private func toolComposer(
        _ profile: SkillModelProfileOption,
        profileOverride: SkillModelOverride
    ) -> some View {
        let customIDs = Set(profileOverride.toolIDs)
        let inheritedIDs = profileOverride.inheritsDefaults
            ? Set(profile.defaultToolIDs.map(\.rawValue))
            : []
        let effectiveIDs = customIDs.union(inheritedIDs)
        let availableTools = ModelToolCatalog.descriptors.filter { descriptor in
            let matchesSearch = viewModel.toolSearchText.isEmpty
                || descriptor.name.localizedCaseInsensitiveContains(viewModel.toolSearchText)
                || descriptor.id.rawValue.localizedCaseInsensitiveContains(viewModel.toolSearchText)
            return matchesSearch && !effectiveIDs.contains(descriptor.id.rawValue)
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Tool composition", systemImage: "rectangle.2.swap")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("Drag tools between lists or use the buttons")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                toolColumn(title: "Available", count: availableTools.count) {
                    TextField("Filter tools", text: $viewModel.toolSearchText)
                        .textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(availableTools) { tool in
                                availableToolRow(tool, profile: profile)
                            }
                        }
                    }
                }
                .background(
                    availableDropIsTargeted ? Color.accentColor.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .dropDestination(for: String.self) { values, _ in
                    let customIDs = Set(profileOverride.toolIDs)
                    let removable = values.filter(customIDs.contains)
                    for value in removable {
                        viewModel.removeTool(value, from: profile)
                    }
                    return !removable.isEmpty
                } isTargeted: { targeted in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        availableDropIsTargeted = targeted
                    }
                }

                toolColumn(title: "Profile", count: effectiveIDs.count) {
                    profileToolList(
                        profile,
                        profileOverride: profileOverride,
                        inheritedIDs: inheritedIDs
                    )
                }
                .background(
                    profileDropIsTargeted ? Color.accentColor.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .dropDestination(for: String.self) { values, _ in
                    var accepted = false
                    for value in values {
                        guard let toolID = ToolCapabilityID(rawValue: value),
                              profile.compatibleToolIDs.contains(toolID),
                              !effectiveIDs.contains(value) else { continue }
                        viewModel.addTool(toolID, to: profile)
                        accepted = true
                    }
                    return accepted
                } isTargeted: { targeted in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        profileDropIsTargeted = targeted
                    }
                }
            }
            .frame(height: 286)
        }
    }

    private func profileToolList(
        _ profile: SkillModelProfileOption,
        profileOverride: SkillModelOverride,
        inheritedIDs: Set<String>
    ) -> some View {
        let customIDs = profileOverride.toolIDs
        let inheritedTools = ModelToolCatalog.descriptors.filter { inheritedIDs.contains($0.id.rawValue) }
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(inheritedTools) { tool in
                    profileToolRow(tool.id.rawValue, inherited: true, profile: profile)
                }
                ForEach(customIDs.filter { !inheritedIDs.contains($0) }, id: \.self) { toolID in
                    profileToolRow(toolID, inherited: false, profile: profile)
                }
                if inheritedTools.isEmpty && customIDs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                        Text("Drop tools here")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 54)
                }
            }
        }
    }

    @ViewBuilder
    private func availableToolRow(
        _ tool: ToolCapabilityDescriptor,
        profile: SkillModelProfileOption
    ) -> some View {
        let compatible = profile.compatibleToolIDs.contains(tool.id)
        let row = HStack(spacing: 8) {
            Image(systemName: tool.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name)
                    .font(.system(size: 11.5, weight: .medium))
                Text(tool.id.rawValue)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if compatible {
                Button {
                    viewModel.addTool(tool.id, to: profile)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Add \(tool.name)")
            } else {
                Text("Unavailable")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .opacity(compatible ? 1 : 0.58)

        if compatible {
            row.draggable(tool.id.rawValue) {
                Label(tool.name, systemImage: tool.systemImage)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            row
        }
    }

    @ViewBuilder
    private func profileToolRow(
        _ toolID: String,
        inherited: Bool,
        profile: SkillModelProfileOption
    ) -> some View {
        let descriptor = ToolCapabilityID(rawValue: toolID).map { ModelToolCatalog.descriptor(for: $0) }
        let row = HStack(spacing: 8) {
            Image(systemName: descriptor?.systemImage ?? "questionmark.circle")
                .foregroundStyle(descriptor == nil ? .orange : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(descriptor?.name ?? toolID)
                    .font(.system(size: 11.5, weight: .medium))
                Text(inherited ? "Inherited" : descriptor?.id.rawValue ?? "Unknown tool ID")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !inherited {
                Button {
                    viewModel.removeTool(toolID, from: profile)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove Tool")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

        if inherited {
            row
        } else {
            row.draggable(toolID) {
                Label(descriptor?.name ?? toolID, systemImage: descriptor?.systemImage ?? "questionmark.circle")
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func toolColumn<Content: View>(
        title: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Text("\(count)")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        }
    }

    private func sectionCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

    private var skillSelection: Binding<String?> {
        Binding(
            get: { viewModel.selectedRecordID },
            set: { viewModel.requestSelection($0) }
        )
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { viewModel.draft?.name ?? "" },
            set: { value in viewModel.updateDraft { $0.name = value } }
        )
    }

    private var descriptionBinding: Binding<String> {
        Binding(
            get: { viewModel.draft?.description ?? "" },
            set: { value in viewModel.updateDraft { $0.description = value } }
        )
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { viewModel.draft?.prompt ?? "" },
            set: { value in viewModel.updateDraft { $0.prompt = value } }
        )
    }

    private var discardAlertPresented: Binding<Bool> {
        Binding(
            get: { viewModel.confirmationMessage != nil },
            set: { if !$0 { viewModel.cancelDiscard() } }
        )
    }

    private var errorAlertPresented: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private func tierLabel(_ tier: ModelToolTier) -> String {
        switch tier {
        case .none: "Unavailable"
        case .onDevice: "On-device"
        case .standard: "Standard"
        case .enhanced: "Enhanced"
        }
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + String(path.dropFirst(home.count))
    }
}
