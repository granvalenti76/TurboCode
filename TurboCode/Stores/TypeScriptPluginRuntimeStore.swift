import Foundation
import Observation

/// Observable projection of plugin lifecycle facts. Discovery and process
/// actors publish verified transitions here; model prose is never a source.
@MainActor
@Observable
final class TypeScriptPluginRuntimeStore {
    static let shared = TypeScriptPluginRuntimeStore()

    private(set) var snapshots: [String: TypeScriptPluginLifecycleSnapshot] = [:]

    var orderedSnapshots: [TypeScriptPluginLifecycleSnapshot] {
        snapshots.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func recordDiscovery(_ result: TypeScriptPluginDiscoveryResult) {
        for plugin in result.plugins where snapshots[plugin.manifest.id]?.stage != .ready {
            update(
                descriptor: plugin,
                stage: .discovered,
                detail: "Manifest and entrypoint are valid."
            )
        }
        for failure in result.failures {
            let id = failure.rootURL.lastPathComponent
            snapshots[id] = TypeScriptPluginLifecycleSnapshot(
                id: id,
                name: id,
                rootURL: failure.rootURL,
                stage: .failed,
                detail: failure.message,
                toolCount: 0,
                widgetCount: 0,
                updatedAt: Date()
            )
        }
    }

    func update(
        descriptor: TypeScriptPluginDescriptor,
        stage: TypeScriptPluginLifecycleStage,
        detail: String
    ) {
        snapshots[descriptor.manifest.id] = TypeScriptPluginLifecycleSnapshot(
            id: descriptor.manifest.id,
            name: descriptor.manifest.name,
            rootURL: descriptor.rootURL,
            stage: stage,
            detail: detail,
            toolCount: descriptor.manifest.tools.count,
            widgetCount: descriptor.manifest.widgets.count,
            updatedAt: Date()
        )
    }

    func update(pluginID: String, stage: TypeScriptPluginLifecycleStage, detail: String) {
        guard let current = snapshots[pluginID] else { return }
        snapshots[pluginID] = TypeScriptPluginLifecycleSnapshot(
            id: current.id,
            name: current.name,
            rootURL: current.rootURL,
            stage: stage,
            detail: detail,
            toolCount: current.toolCount,
            widgetCount: current.widgetCount,
            updatedAt: Date()
        )
    }
}
