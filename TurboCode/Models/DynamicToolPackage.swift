import Foundation

/// A small, stable capability bundle selected by the experimental Dynamic
/// router. The bundle is intersected with the active profile before tools are
/// materialized, so routing never widens a user's explicit capability boundary.
nonisolated enum DynamicToolPackage: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case conversation
    case exploration
    case coding
    case git
    case build
    case implementation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversation: "Conversation"
        case .exploration: "Explore"
        case .coding: "Code"
        case .git: "Git"
        case .build: "Build"
        case .implementation: "Implement"
        }
    }

    var summary: String {
        switch self {
        case .conversation:
            "Answer without workspace tools."
        case .exploration:
            "Inspect files, search the workspace, and read repository structure."
        case .coding:
            "Inspect and edit source files with the profile's safeguards."
        case .git:
            "Inspect the repository and its current Git state."
        case .build:
            "Inspect, build, test, and diagnose the workspace."
        case .implementation:
            "Inspect, edit, run checks, and work with Git."
        }
    }

    /// Descriptions are deliberately contrastive because the encoder chooses
    /// among these strings rather than generating a free-form tool plan.
    var classifierDescription: String {
        switch self {
        case .conversation:
            "Ciao, grazie, spiegami un concetto, parliamo di un'idea. General conversation, explanations, questions and planning without inspecting or changing project files."
        case .exploration:
            "Mostra i file del progetto, leggi un file, cerca una funzione, esplora le cartelle. List workspace files, read source, search for symbols and understand the repository structure."
        case .coding:
            "Correggi un errore nel codice, risolvi un bug, modifica un file, aggiungi una funzione. Fix a bug, edit source code, implement a feature, refactor an existing function."
        case .git:
            "Controlla lo stato git, mostra il diff, i branch e la storia dei commit. Inspect Git status, branches, commits, diffs, history and repository changes."
        case .build:
            "Compila il progetto, esegui i test, mostra il risultato della build. Run the existing tests, build the Xcode project, inspect compiler diagnostics and build settings."
        case .implementation:
            "Implementa la feature e verifica con i test. Correggi il bug e compila. Modifica il codice e fai commit. Implement code changes AND run tests or build or commit them."
        }
    }

    var toolIDs: Set<ToolCapabilityID> {
        switch self {
        case .conversation:
            []
        case .exploration:
            [.listWorkspace, .fileSystem, .readFile, .searchWorkspace]
        case .coding:
            [.listWorkspace, .swiftWorkspaceMap, .readFile, .searchWorkspace, .editFile, .fileSystem, .loadSkill]
        case .git:
            [.listWorkspace, .readFile, .searchWorkspace, .git]
        case .build:
            [.listWorkspace, .readFile, .searchWorkspace, .swiftWorkspaceMap, .xcodeProject, .swiftPackageManager, .bash]
        case .implementation:
            [.listWorkspace, .swiftWorkspaceMap, .readFile, .searchWorkspace, .fileSystem, .git, .bash, .swiftPackageManager, .xcodeProject, .editFile, .loadSkill]
        }
    }
}

nonisolated struct DynamicRoutingDecision: Sendable, Equatable {
    enum Source: String, Sendable, Equatable {
        case model
        case fallback
    }

    let package: DynamicToolPackage
    let toolIDs: Set<ToolCapabilityID>
    let topScore: Double
    let margin: Double
    let source: Source
    let latencyMilliseconds: Double
    /// A fallback must be visible: it is not evidence that CoreAI ran.
    var fallbackReason: String? = nil
}

/// Resolves the candidate catalog and keeps the Dynamic feature independent
/// from the closed model-facing tool catalog implementation.
nonisolated enum DynamicToolPackageResolver {
    static func candidates(allowedToolIDs: Set<ToolCapabilityID>, prompt: String = "") -> [DynamicToolPackage] {
        DynamicToolPackage.allCases.filter { package in
            // A package is meaningful only when the active profile can provide
            // its complete capability set; routing must never manufacture a
            // partial package and present it as a different operating mode.
            (package == .conversation || package.toolIDs.isSubset(of: allowedToolIDs))
                && (package != .implementation || requestsCombinedWork(prompt))
        }
    }

    /// The broad package requires explicit edit-and-verify intent. Embedding
    /// similarity alone tends to favor this catch-all description.
    private static func requestsCombinedWork(_ prompt: String) -> Bool {
        let text = prompt.lowercased()
        let edits = ["implement", "modific", "corregg", "refactor", "fix", "edit", "change"]
        let checks = ["test", "compil", "build", "verific", "commit"]
        return edits.contains(where: text.contains) && checks.contains(where: text.contains)
    }

    static func effectiveToolIDs(
        for package: DynamicToolPackage,
        allowedToolIDs: Set<ToolCapabilityID>
    ) -> Set<ToolCapabilityID> {
        package.toolIDs.intersection(allowedToolIDs)
    }
}
