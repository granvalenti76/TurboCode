import Foundation

// MARK: - Runtime port

/// The only interface TurboCode uses to drive the Cowork VM.
///
/// Containerization stays behind this protocol (see
/// `ContainerizationCoworkRuntime`), so the pre-1.0 dependency is confined to
/// one adapter and every caller can be tested with a fake runtime.
/// `nonisolated` is required: the app target defaults to MainActor, and VM
/// work must never be funneled through the main thread.
nonisolated protocol CoworkVMRuntime: Sendable {
    /// Boots the VM, or restarts it when the requested configuration differs
    /// from the running one. The writable layer persists across restarts.
    func start(_ configuration: CoworkVMConfiguration) async throws
    /// Runs one command in the guest. The stream yields output as it arrives
    /// and always ends with exactly one `.exited` or `.timedOut` event.
    func exec(_ request: CoworkExecRequest) async throws -> AsyncThrowingStream<CoworkExecEvent, any Error>
    func stop() async throws
    /// Stops the VM and discards the writable layer. The base image stays
    /// installed, so the next start boots a clean guest without downloads.
    func reset() async throws
    func state() async -> CoworkVMState
}

/// Installation steps that need Containerization's image store. Implemented
/// next to the runtime adapter so the dependency stays in one file.
nonisolated protocol CoworkImageProvisioning: Sendable {
    /// Fetches the pinned `vminit` image and writes the init filesystem.
    func prepareInitFilesystem() async throws
    /// Pulls the pinned guest image into the content store. `progress`
    /// receives a 0...1 fraction when the registry reports sizes.
    func pullImage(progress: @escaping @Sendable (Double?) -> Void) async throws
    /// Unpacks the pinned image into the read-only base rootfs, atomically.
    func unpackBaseRootfs(progress: @escaping @Sendable (Double?) -> Void) async throws
}

// MARK: - Values

nonisolated struct CoworkVMConfiguration: Sendable, Equatable {
    static let defaultCPUs = 4
    static let defaultMemoryBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024

    var cpus: Int = Self.defaultCPUs
    var memoryBytes: UInt64 = Self.defaultMemoryBytes
    var networkEnabled = true
    /// Host folder exposed read-only at `/work`; `nil` mounts nothing.
    var inputFolder: URL?
    /// Host staging folder exposed read-write at `/out`.
    var outbox: URL
}

nonisolated enum CoworkVMState: Sendable, Equatable {
    case stopped
    case running(CoworkVMConfiguration)
}

nonisolated struct CoworkExecRequest: Sendable, Equatable {
    /// Guest identity. The agent works as the unprivileged image user so
    /// Chromium keeps its sandbox; `root` is reserved for TurboCode itself.
    enum User: Sendable, Equatable {
        case agent
        case root
    }

    static let agentUID: UInt32 = 1_000
    static let maximumTimeout: Duration = .seconds(3_600)

    var script: String
    var workingDirectory = "/home/cowork"
    var user: User = .agent
    var timeout: Duration = .seconds(120)
    var environment: [String: String] = [:]
    /// Bytes delivered on standard input, then closed. File writes use this
    /// instead of embedding content in the script, so no shell quoting can
    /// corrupt or inject into what the model wrote.
    var stdin: Data?

    /// Rejects requests the adapter must never forward: empty scripts,
    /// relative guest paths, and unbounded or non-positive timeouts.
    func validated() throws -> Self {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoworkVMError.invalidRequest("The command is empty.")
        }
        guard workingDirectory.hasPrefix("/") else {
            throw CoworkVMError.invalidRequest("The working directory must be an absolute guest path.")
        }
        guard timeout > .zero, timeout <= Self.maximumTimeout else {
            throw CoworkVMError.invalidRequest("The timeout must be between 1 second and 1 hour.")
        }
        return self
    }
}

nonisolated enum CoworkExecEvent: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
    case exited(Int32)
    case timedOut
}

nonisolated enum CoworkVMError: LocalizedError, Equatable {
    case notInstalled(String)
    case notRunning
    case invalidRequest(String)
    case unsafeInputFolder(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let detail): "Cowork is not installed: \(detail)"
        case .notRunning: "The Cowork VM is not running."
        case .invalidRequest(let detail): detail
        case .unsafeInputFolder(let path): "\(path) cannot be shared with the Cowork VM."
        }
    }
}

// MARK: - Pure planning

/// Decides what the runtime must do for a start request. Pure, so lifecycle
/// rules are tested without a VM.
nonisolated enum CoworkVMLifecycle {
    enum Action: Sendable, Equatable {
        case none
        case start
        case restart
    }

    static func action(current: CoworkVMState, requested: CoworkVMConfiguration) -> Action {
        switch current {
        case .stopped:
            .start
        case .running(let running):
            // Mounts and resources are fixed when the VM boots, so any change
            // needs a restart (≈0.4 s); the writable layer is preserved.
            running == requested ? .none : .restart
        }
    }
}

/// The complete list of host paths shared with the guest. Anything not listed
/// here is invisible to the VM; tests assert this stays exactly two entries.
nonisolated enum CoworkMountPlan {
    struct Share: Sendable, Equatable {
        let hostPath: String
        let guestPath: String
        let readOnly: Bool
    }

    static let inputGuestPath = "/work"

    /// The single rule for which Mac folder may be shared, used both when the
    /// user attaches a folder and when the VM boots. Returns the resolved path.
    static func validatedInputFolder(
        _ folder: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> String {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        // Sharing the whole disk or the whole home folder would expose keys,
        // credentials, and other projects, even read-only.
        guard path != "/", path != home, path.hasPrefix("/") else {
            throw CoworkVMError.unsafeInputFolder(path)
        }
        return path
    }
    static let outboxGuestPath = "/out"

    static func shares(
        for configuration: CoworkVMConfiguration,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> [Share] {
        var shares: [Share] = []
        if let input = configuration.inputFolder {
            let path = try validatedInputFolder(input, homeDirectory: homeDirectory)
            shares.append(Share(hostPath: path, guestPath: inputGuestPath, readOnly: true))
        }
        shares.append(Share(
            hostPath: configuration.outbox.standardizedFileURL.path,
            guestPath: outboxGuestPath,
            readOnly: false
        ))
        return shares
    }
}
