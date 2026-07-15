import SwiftUI

struct ToolsView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openSettings) private var openSettings
    @State private var viewModel = ToolsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                environmentSummary
                modelOverview
                capabilityMatrix
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 1500, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task {
            reload(refreshConfiguration: true)
        }
        .onChange(of: settings.remoteModels) { _, _ in reload() }
        .onChange(of: settings.agentTuning) { _, _ in reload() }
        .onChange(of: chatStore.workspaceRoot) { _, _ in reload() }
        .onChange(of: chatStore.activeRemoteModelID) { _, _ in reload() }
        .onChange(of: chatStore.orchestratorMode) { _, _ in reload() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tools")
                    .font(.system(size: 28, weight: .semibold))
                Text("See which capabilities each model profile receives at runtime.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                openSettings()
            } label: {
                Label("Model Settings", systemImage: "gearshape")
            }
            .controlSize(.regular)
        }
    }

    private var environmentSummary: some View {
        HStack(spacing: 18) {
            summaryItem(
                icon: "doc.badge.gearshape",
                title: "Configuration",
                value: viewModel.configurationPath
            )
            Divider().frame(height: 30)
            summaryItem(
                icon: "folder",
                title: "Workspace",
                value: viewModel.workspaceLabel
            )
            Divider().frame(height: 30)
            summaryItem(
                icon: "puzzlepiece.extension",
                title: "Skills",
                value: "\(viewModel.installedSkillCount) installed"
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
    }

    private func summaryItem(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.system(size: 11.5, weight: .medium, design: title == "Configuration" ? .monospaced : .default))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var modelOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Model profiles", subtitle: "Resolved from Settings and ~/.turbocode/models.json")

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 245, maximum: 340), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(viewModel.profiles) { profile in
                    modelCard(profile)
                }
            }
        }
    }

    private func modelCard(_ profile: ToolModelProfileViewState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: profile.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(profile.isUsable ? Color.accentColor : .secondary)
                    .frame(width: 32, height: 32)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(1)
                        if profile.isActive {
                            Text("ACTIVE")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(profile.subtitle)
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }

            Text(profile.modelIdentifier)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Label(profile.tierLabel, systemImage: "gauge.with.dots.needle.33percent")
                Spacer()
                Text("\(profile.registeredToolCount) tools")
            }
            .font(AppTypography.metadata)
            .foregroundStyle(.secondary)

            HStack(spacing: 5) {
                Circle()
                    .fill(profile.isUsable ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(profile.statusLabel)
                    .font(AppTypography.metadata)
                    .foregroundStyle(profile.isUsable ? .secondary : .tertiary)
            }
        }
        .padding(13)
        .background(.quaternary.opacity(profile.isActive ? 0.32 : 0.16), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    profile.isActive
                        ? Color.accentColor.opacity(0.32)
                        : Color(nsColor: .separatorColor).opacity(0.45),
                    lineWidth: 1
                )
        }
        .opacity(profile.isUsable ? 1 : 0.72)
    }

    private var capabilityMatrix: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                sectionTitle("Capability matrix", subtitle: "Actual registration for the current workspace and configuration")
                Spacer()
                legend
            }

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    matrixHeader
                    Divider()
                    ForEach(ToolCapabilityCategory.allCases, id: \.self) { category in
                        categoryHeader(category)
                        ForEach(viewModel.tools.filter { $0.category == category }) { tool in
                            toolRow(tool)
                            Divider().padding(.leading, 252)
                        }
                    }
                }
                .padding(.bottom, 1)
            }
            .scrollIndicators(.visible)
            .background(.quaternary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
            RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            }
        }
    }

    private var matrixHeader: some View {
        HStack(spacing: 0) {
            Text("TOOL")
                .frame(width: 252, alignment: .leading)
            ForEach(viewModel.profiles) { profile in
                Text(profile.name)
                    .lineLimit(2)
                    .frame(width: 148)
            }
        }
        .font(.system(size: 9.5, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func categoryHeader(_ category: ToolCapabilityCategory) -> some View {
        Text(category.rawValue.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 5)
    }

    private func toolRow(_ tool: ToolCapabilityDescriptor) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: tool.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(tool.name)
                            .font(.system(size: 12, weight: .medium))
                        if tool.hasNativePresentation {
                            Image(systemName: "rectangle.on.rectangle")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.accentColor)
                                .help("Native timeline presentation")
                        }
                    }
                    Text(tool.summary)
                        .font(AppTypography.metadata)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 252, alignment: .leading)

            ForEach(viewModel.profiles) { profile in
                capabilityCell(toolID: tool.id, profile: profile)
                    .frame(width: 148)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func capabilityCell(
        toolID: ToolCapabilityID,
        profile: ToolModelProfileViewState
    ) -> some View {
        let assignment = profile.plan.assignment(for: toolID)
        return HStack(spacing: 5) {
            if assignment == nil {
                Image(systemName: "minus")
                    .foregroundStyle(.quaternary)
            } else if !profile.isUsable {
                Image(systemName: "circle.slash")
                    .foregroundStyle(.tertiary)
            } else if assignment?.isRegistered == true {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.orange)
            }

            Text(capabilityLabel(assignment, profile: profile))
                .lineLimit(1)
        }
        .font(AppTypography.metadata)
        .foregroundStyle(.secondary)
        .help(capabilityHelp(assignment, profile: profile))
    }

    private func capabilityLabel(
        _ assignment: ModelToolAssignment?,
        profile: ToolModelProfileViewState
    ) -> String {
        guard assignment != nil else { return "—" }
        guard profile.isUsable else { return profile.statusLabel }
        return assignment?.isRegistered == true ? "Ready" : "Conditional"
    }

    private func capabilityHelp(
        _ assignment: ModelToolAssignment?,
        profile: ToolModelProfileViewState
    ) -> String {
        guard assignment != nil else { return "Not included in this profile" }
        guard profile.isUsable else { return profile.statusLabel }
        return assignment?.unavailableReason ?? "Registered in the current session profile"
    }

    private var legend: some View {
        HStack(spacing: 12) {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Label("Requires context", systemImage: "circle.dashed")
                .foregroundStyle(.orange)
            Label("Not included", systemImage: "minus")
                .foregroundStyle(.secondary)
        }
        .font(AppTypography.metadata)
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(subtitle)
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
        }
    }

    private func reload(refreshConfiguration: Bool = false) {
        viewModel.reload(
            settings: settings,
            chatStore: chatStore,
            refreshConfiguration: refreshConfiguration
        )
    }
}
