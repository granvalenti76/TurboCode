import Foundation
import Observation

/// Presentation state and preferences for Cowork, owned by `SettingsStore`.
///
/// It owns the app's single `ContainerizationCoworkRuntime`, because Cowork has
/// exactly one VM. Later slices hand that runtime to tools through a narrow
/// port; nothing here is reachable from tools directly.
@MainActor
@Observable
final class CoworkStore {
    enum Phase: Equatable {
        case notInstalled
        case installing(CoworkInstallStep, fraction: Double?)
        case ready
        case failed(String)
    }

    /// Approximate sizes for the confirmation dialog, measured on v0.62.0-rc.1/rc.2
    /// (kernel 29 MB + image layers and init ≈ 730 MB; disk ≈ 2.2 GB).
    static let approximateDownload = "about 760 MB"
    static let approximateDiskUse = "about 2.2 GB"

    private(set) var phase: Phase = .notInstalled
    private(set) var lastVerificationOutput: String?
    private(set) var diskUsageBytes: Int64?

    /// Cowork is usable only when the user enabled it and the guest is ready.
    var isAvailable: Bool { isEnabled && phase == .ready }
    var isInstalling: Bool { if case .installing = phase { true } else { false } }

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }
    var cpus: Int {
        didSet { defaults.set(cpus, forKey: Keys.cpus) }
    }
    var memoryGiB: Int {
        didSet { defaults.set(memoryGiB, forKey: Keys.memory) }
    }
    var networkEnabled: Bool {
        didSet { defaults.set(networkEnabled, forKey: Keys.network) }
    }

    let runtime: ContainerizationCoworkRuntime
    private let installer: CoworkInstaller
    private let layout: CoworkSandboxLayout
    private let defaults: UserDefaults
    private var installTask: Task<Void, Never>?

    init(
        descriptor: CoworkImageDescriptor = .current,
        layout: CoworkSandboxLayout = .init(),
        defaults: UserDefaults = .standard
    ) {
        let runtime = ContainerizationCoworkRuntime(descriptor: descriptor, layout: layout)
        self.runtime = runtime
        self.layout = layout
        self.defaults = defaults
        self.installer = CoworkInstaller(
            descriptor: descriptor,
            layout: layout,
            provisioner: ContainerizationCoworkProvisioner(descriptor: descriptor, layout: layout),
            runtime: runtime
        )
        isEnabled = defaults.bool(forKey: Keys.enabled)
        cpus = (defaults.object(forKey: Keys.cpus) as? Int) ?? CoworkVMConfiguration.defaultCPUs
        memoryGiB = (defaults.object(forKey: Keys.memory) as? Int)
            ?? Int(CoworkVMConfiguration.defaultMemoryBytes / 1_073_741_824)
        networkEnabled = (defaults.object(forKey: Keys.network) as? Bool) ?? true
        refreshStatus()
    }

    /// The configuration the VM boots with. Resource changes apply on the next
    /// start, because the runtime restarts when the configuration differs.
    func configuration(inputFolder: URL? = nil) -> CoworkVMConfiguration {
        CoworkVMConfiguration(
            cpus: cpus,
            memoryBytes: UInt64(memoryGiB) * 1_073_741_824,
            networkEnabled: networkEnabled,
            inputFolder: inputFolder,
            outbox: layout.outbox
        )
    }

    func refreshStatus() {
        if !isInstalling {
            phase = installer.status() == .ready ? .ready : .notInstalled
        }
        refreshDiskUsage()
    }

    // MARK: Actions

    func install() {
        guard !isInstalling else { return }
        phase = .installing(.downloadingKernel, fraction: nil)
        let installer = installer
        let configuration = configuration()
        let report: CoworkInstaller.StepReporter = { [weak self] step, fraction in
            guard let store = self else { return }
            Task { @MainActor in store.applyProgress(step, fraction: fraction) }
        }
        installTask = Task { [weak self] in
            do {
                let output = try await installer.install(configuration: configuration, report: report)
                self?.lastVerificationOutput = output
                self?.phase = .ready
            } catch is CancellationError {
                self?.phase = .notInstalled
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
            self?.installTask = nil
            self?.refreshDiskUsage()
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    /// Discards everything the agent changed in the guest; the base stays.
    func resetVM() async throws {
        try await runtime.reset()
        refreshDiskUsage()
    }

    /// Stops the VM and deletes every Cowork file. Sessions are kept.
    func removeAll() async throws {
        installTask?.cancel()
        try await runtime.stop()
        try installer.uninstall()
        isEnabled = false
        lastVerificationOutput = nil
        phase = .notInstalled
        refreshDiskUsage()
    }

    /// Progress hops arrive asynchronously; late updates from a step the
    /// installer already left are ignored so the bar never moves backwards.
    private func applyProgress(_ step: CoworkInstallStep, fraction: Double?) {
        guard case .installing(let current, _) = phase,
              Self.order(step) >= Self.order(current) else { return }
        phase = .installing(step, fraction: fraction)
    }

    private static func order(_ step: CoworkInstallStep) -> Int {
        CoworkInstallStep.allCases.firstIndex(of: step) ?? 0
    }

    // MARK: Disk usage

    private func refreshDiskUsage() {
        let root = layout.root
        Task.detached(priority: .utility) { [weak self] in
            let bytes = Self.allocatedSize(of: root)
            await MainActor.run { self?.diskUsageBytes = bytes }
        }
    }

    /// Allocated (not logical) size: the VM disks are sparse files whose
    /// nominal capacity is far larger than what they use.
    nonisolated private static func allocatedSize(of root: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else { return nil }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize
            total += Int64(size ?? 0)
        }
        return total
    }

    private enum Keys {
        static let enabled = "coworkEnabled"
        static let cpus = "coworkCPUs"
        static let memory = "coworkMemoryGiB"
        static let network = "coworkNetworkEnabled"
    }
}
