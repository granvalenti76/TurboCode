import Foundation

/// Stable roles shown by Activity and used to constrain model capabilities.
nonisolated enum AgentModelRole: String, Codable, Sendable, Hashable {
    case microtaskOnDevice = "microtask_on_device"
    case codingWorker = "coding_worker"
    case powerfulCoordinator = "powerful_coordinator"
    case experimentalOnDeviceCoordinator = "experimental_on_device_coordinator"
}

/// A route selected from explicit profile/runtime state, never from a model's
/// subjective assessment of the user's prompt.
nonisolated struct ModelRoutingDecision: Sendable, Hashable {
    let role: AgentModelRole
    let profile: ModelRuntimeProfile
    let supportsStructuredDelegation: Bool
}

/// Deterministic 0.2.0 routing policy.
///
/// The user-selected profile is authoritative: TurboCode does not ask the
/// on-device model to decide whether a task deserves a stronger model.
nonisolated enum ModelRoutingPolicy {
    static func resolve(
        backend: ModelBackend,
        mode: OrchestratorMode,
        activeProfile: UserDynamicProfile?
    ) -> ModelRoutingDecision {
        if mode == .orchestrator {
            return ModelRoutingDecision(
                role: .experimentalOnDeviceCoordinator,
                profile: .orchestrator,
                supportsStructuredDelegation: false
            )
        }
        if backend != .foundationApple,
           activeProfile?.resolvedToolIDs.contains(.delegateTask) == true {
            return ModelRoutingDecision(
                role: .powerfulCoordinator,
                profile: .standalone,
                supportsStructuredDelegation: true
            )
        }
        if backend == .foundationApple {
            return ModelRoutingDecision(
                role: .microtaskOnDevice,
                profile: .microtask,
                supportsStructuredDelegation: false
            )
        }
        return ModelRoutingDecision(
            role: .codingWorker,
            profile: .standalone,
            supportsStructuredDelegation: false
        )
    }
}

/// Measured competence envelope for Apple's on-device model in 0.2.0.
///
/// These limits describe product assignment policy, not a correctness claim.
/// Deterministic validation must still verify every generated artifact.
nonisolated enum OnDeviceCapabilityPolicy {
    static let maximumSnippetLines = 30
    static let allowsMultiFileChanges = false
    static let requiresProvidedSignatureAndContext = true

    static let directToolIDs: Set<ToolCapabilityID> = [
        .turboCodeGuide,
        .listWorkspace,
        .writeOnDevice
    ]

    /// Applies only high-confidence textual rules at the composer boundary.
    /// Ambiguous prompts remain eligible; the app never asks the small model
    /// to judge its own competence or silently changes the selected profile.
    static func assignment(for request: String) -> OnDeviceTaskAssignment {
        let normalized = request
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let referencedFiles = Set(
            normalized
                .split(whereSeparator: \.isWhitespace)
                .map {
                    $0.trimmingCharacters(
                        in: CharacterSet(charactersIn: "`'\"(),:;.!?[]{}")
                    )
                }
                .filter(Self.looksLikeFileReference)
        )
        if referencedFiles.count > 1
            || Self.multiFileMarkers.contains(where: normalized.contains) {
            return .requiresCapableModel(.multiFile)
        }
        if Self.architectureMarkers.contains(where: normalized.contains) {
            return .requiresCapableModel(.architecture)
        }
        return .eligibleMicrotask
    }

    static func validateGeneratedFile(
        name: String,
        content: String
    ) throws {
        guard URL(fileURLWithPath: name).pathExtension.lowercased() == "swift" else {
            return
        }
        var lines = content.components(separatedBy: .newlines)
        if content.hasSuffix("\n") {
            lines.removeLast()
        }
        guard lines.count <= maximumSnippetLines else {
            throw OnDeviceCapabilityError.swiftSnippetTooLarge(
                lines: lines.count,
                maximum: maximumSnippetLines
            )
        }
    }

    private static let multiFileMarkers = [
        "multi-file",
        "multiple files",
        "two files",
        "several files",
        "piu file",
        "due file",
        "diversi file",
        "tutti i file",
        "across the project",
        "in tutto il progetto"
    ]

    private static let architectureMarkers = [
        "architecture",
        "architectural",
        "architettura",
        "architetturale",
        "refactor the project",
        "refactor dell'intero progetto",
        "redesign the project",
        "riprogetta il progetto",
        "modularize the project",
        "modularizza il progetto"
    ]

    private static func looksLikeFileReference(_ token: String) -> Bool {
        let supportedExtensions = [
            ".swift", ".m", ".mm", ".h", ".json", ".md", ".plist",
            ".xcodeproj", ".xcworkspace"
        ]
        return supportedExtensions.contains { token.hasSuffix($0) }
    }
}

/// Deterministic composer-level boundary for the on-device microtask profile.
nonisolated enum OnDeviceTaskAssignment: Sendable, Hashable {
    case eligibleMicrotask
    case requiresCapableModel(OnDeviceTaskBoundaryReason)

    var allowsOnDevice: Bool {
        self == .eligibleMicrotask
    }

    var guidance: String? {
        switch self {
        case .eligibleMicrotask:
            nil
        case .requiresCapableModel(.multiFile):
            "This request affects multiple files. Select a coding worker or coordinator."
        case .requiresCapableModel(.architecture):
            "This architectural request needs a coordinator or coding worker."
        }
    }
}

nonisolated enum OnDeviceTaskBoundaryReason: String, Sendable, Hashable {
    case multiFile
    case architecture
}

nonisolated enum OnDeviceCapabilityError: LocalizedError, Sendable, Equatable {
    case swiftSnippetTooLarge(lines: Int, maximum: Int)

    var errorDescription: String? {
        switch self {
        case .swiftSnippetTooLarge(let lines, let maximum):
            "On-device Swift output is limited to \(maximum) lines; received \(lines). Select a coding-worker or coordinator profile."
        }
    }
}
