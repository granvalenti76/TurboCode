import Foundation

nonisolated enum TypeScriptPluginLifecycleStage: String, Sendable, Equatable {
    case discovered
    case validating
    case building
    case awaitingAuthorization
    case installed
    case activating
    case ready
    case denied
    case failed
}

nonisolated struct TypeScriptPluginLifecycleSnapshot: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let rootURL: URL
    let stage: TypeScriptPluginLifecycleStage
    let detail: String
    let toolCount: Int
    let widgetCount: Int
    let updatedAt: Date
}
