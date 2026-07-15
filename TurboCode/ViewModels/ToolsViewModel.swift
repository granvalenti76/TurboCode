import Foundation
import FoundationModels
import Observation

nonisolated struct ToolModelProfileViewState: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let modelIdentifier: String
    let systemImage: String
    let tierLabel: String
    let statusLabel: String
    let isUsable: Bool
    let isActive: Bool
    let plan: ModelToolPlan

    var registeredToolCount: Int {
        isUsable ? plan.assignments.filter(\.isRegistered).count : 0
    }
}

@MainActor
@Observable
final class ToolsViewModel {
    private(set) var profiles: [ToolModelProfileViewState] = []
    private(set) var tools: [ToolCapabilityDescriptor] = ModelToolCatalog.descriptors
    private(set) var configurationPath = "~/.turbocode/models.json"
    private(set) var workspaceLabel = "No workspace selected"
    private(set) var installedSkillCount = 0

    func reload(
        settings: SettingsStore,
        chatStore: ChatStore,
        refreshConfiguration: Bool = false
    ) {
        if refreshConfiguration {
            settings.reloadRemoteModels()
        }

        let context = ToolAccessContext(
            hasWorkspace: !chatStore.workspaceRoot.isEmpty,
            hasSkills: !chatStore.availableSkills.isEmpty,
            hasDelegateModel: settings.selectedOrchestratorModel?.enabled == true
        )
        workspaceLabel = chatStore.workspaceRoot.isEmpty
            ? "No workspace selected"
            : chatStore.workspaceLabel
        installedSkillCount = chatStore.availableSkills.count
        configurationPath = abbreviatedPath(TurboCodeConfig.shared.modelsConfigurationURL.path)

        let onDeviceSupportsTools = SystemLanguageModel.default.capabilities.contains(.toolCalling)
        let onDeviceTier: ModelToolTier = onDeviceSupportsTools ? .onDevice : .none
        let isOrchestrating = chatStore.orchestratorMode == .orchestrator
        let delegateName = settings.selectedOrchestratorModel?.name ?? "No delegate configured"

        var resolvedProfiles: [ToolModelProfileViewState] = [
            ToolModelProfileViewState(
                id: "apple-on-device-standalone",
                name: "Apple On-Device",
                subtitle: "Standalone · Private and immediate",
                modelIdentifier: "SystemLanguageModel.default",
                systemImage: "apple.logo",
                tierLabel: "On-device",
                statusLabel: onDeviceSupportsTools ? "Available" : "Tool calling unavailable",
                isUsable: onDeviceSupportsTools,
                isActive: chatStore.activeBackend == .foundationApple && !isOrchestrating,
                plan: ModelToolCatalog.plan(
                    profile: .standalone,
                    tier: onDeviceTier,
                    context: context
                )
            ),
            ToolModelProfileViewState(
                id: "apple-on-device-orchestrator",
                name: "Apple Orchestrator",
                subtitle: "Coordinates locally · Delegates to \(delegateName)",
                modelIdentifier: settings.agentTuning.orchestrator.delegateModelID,
                systemImage: "point.3.connected.trianglepath.dotted",
                tierLabel: "Orchestrator",
                statusLabel: context.hasDelegateModel ? "Available" : "Delegate required",
                isUsable: onDeviceSupportsTools && context.hasDelegateModel,
                isActive: isOrchestrating,
                plan: ModelToolCatalog.plan(
                    profile: .orchestrator,
                    tier: onDeviceTier,
                    context: context
                )
            )
        ]

        resolvedProfiles += settings.remoteModels.map { model in
            let configured = settings.isConfigured(model)
            let status: String
            if !model.enabled {
                status = "Disabled"
            } else if !configured {
                status = "Credential required"
            } else {
                status = "Available"
            }
            return ToolModelProfileViewState(
                id: "remote-\(model.id)",
                name: model.name,
                subtitle: "\(roleLabel(model.role)) · \(providerLabel(model.provider))",
                modelIdentifier: model.modelName,
                systemImage: modelIcon(model),
                tierLabel: "Standard",
                statusLabel: status,
                isUsable: model.enabled && configured,
                isActive: !isOrchestrating && chatStore.activeRemoteModelID == model.id,
                plan: ModelToolCatalog.plan(
                    profile: .standalone,
                    tier: .standard,
                    context: context
                )
            )
        }

        profiles = resolvedProfiles
    }

    private func roleLabel(_ role: RemoteModelRole) -> String {
        switch role {
        case .local: "Local"
        case .pcc: "Private Cloud Compute"
        case .premium: "Premium"
        }
    }

    private func providerLabel(_ provider: RemoteModelProvider) -> String {
        switch provider {
        case .openAICompatible: "OpenAI-compatible"
        case .deepseek: "DeepSeek"
        }
    }

    private func modelIcon(_ model: RemoteModelConfig) -> String {
        switch model.role {
        case .local: "desktopcomputer"
        case .pcc: "cloud"
        case .premium: "sparkles"
        }
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + String(path.dropFirst(home.count))
    }
}
