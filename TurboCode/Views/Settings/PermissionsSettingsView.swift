import SwiftUI

// MARK: - Permissions Settings

/// Every switch that lets agents reach beyond the workspace, in one pane.
///
/// These toggles used to be spread across Execution and an "Experimental"
/// section of the Agents tab. They share one property: turning them on widens
/// what a model can touch, so the user reviews them together. All default to
/// off in `AgentTuningConfig`; this pane only edits them. The runtime publish
/// happens in `SettingsRootView`, which observes `agentTuning`.
///
/// Studio's VM network setting is deliberately not mirrored here: the VM is a
/// separate trust boundary with its own lifecycle, so this pane links to it.
struct PermissionsSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openSettingsSection) private var openSettingsSection

    var body: some View {
        let s = Bindable(settings)
        return Form {
            SettingsPaneHeader(section: .permissions)

            Section("Network") {
                Toggle(isOn: s.agentTuning.execution.allowNetworkAccess) {
                    Text("Allow network access for commands")
                    Text("Applies to commands that agents run on this Mac in Coding sessions.")
                }

                LabeledContent {
                    Button("Studio Settings…") { openSettingsSection(.cowork) }
                } label: {
                    Text("Studio virtual machine")
                    Text("Set separately, because the VM is isolated from this Mac.")
                }
            }

            Section("Apple Integrations") {
                Toggle(isOn: s.agentTuning.experimental.xcodeMCPEnabled) {
                    Text("Xcode MCP")
                    Text("The active model can discover and call Xcode's MCP tools through xcrun mcpbridge. Enable external agents in Xcode Intelligence settings first.")
                }

                Toggle(isOn: s.agentTuning.experimental.safariMCPEnabled) {
                    Text("Safari MCP")
                    Text("A skill you activate can control Safari through safaridriver MCP.")
                }
            }

            Section("Plugins") {
                Toggle(isOn: s.agentTuning.experimental.thirdPartyPluginsEnabled) {
                    Text("Allow third-party plugins")
                    Text("Installed Node.js plugins can start and expose tools to selected profiles. They run as normal local processes with filesystem, network, and subprocess access.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
