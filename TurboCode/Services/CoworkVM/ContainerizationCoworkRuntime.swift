import Containerization
import ContainerizationEXT4
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Synchronization
import SystemPackage

/// `CoworkVMRuntime` backed by Apple Containerization 0.49.0.
///
/// This is the only file that imports Containerization. The package is pre-1.0
/// and source-stable only within a minor version, so it is pinned with
/// `exact:` and every upgrade must re-run the `spike/cowork-vm` checks.
///
/// Shape validated by the spike: one persistent guest made of a read-only base
/// rootfs (unpacked once from the pinned image) plus a persistent writable
/// overlay, a long-lived `sleep infinity` process, and work run through `exec`.
/// Installation (kernel download, image pull, unpack) is the installer's job;
/// this runtime only boots what is already installed.
actor ContainerizationCoworkRuntime: CoworkVMRuntime {
    nonisolated static let containerID = "cowork"
    nonisolated static let hostname = "cowork"
    /// Sparse capacity of the writable layer; actual disk use grows on demand.
    nonisolated static let writableLayerBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024

    private let descriptor: CoworkImageDescriptor
    private let layout: CoworkSandboxLayout
    private var manager: ContainerManager?
    private var container: LinuxContainer?
    private var running: CoworkVMConfiguration?
    private var execCounter = 0
    /// Serializes `start`, `stop`, `reset`, and the launch half of `exec`.
    /// The private `perform…` methods assume they already run inside it and
    /// must never enqueue again, or they would wait on themselves.
    private let lifecycle = CoworkLifecycleQueue()
    /// Guest processes still running, so a cancelled consumer can kill its own.
    private var activeExecs: [Int: LinuxProcess] = [:]
    /// Execs a stop or reset ended; they report `.interrupted`, not a timeout.
    private var interruptedExecs: Set<Int> = []

    init(descriptor: CoworkImageDescriptor = .current, layout: CoworkSandboxLayout = .init()) {
        self.descriptor = descriptor
        self.layout = layout
    }

    func state() -> CoworkVMState {
        running.map(CoworkVMState.running) ?? .stopped
    }

    func start(_ configuration: CoworkVMConfiguration) async throws {
        try await lifecycle.run { try await self.performStart(configuration) }
    }

    /// Only the launch is queued, so a command never starts in a VM that is
    /// still booting or already stopping. Its output streams outside the
    /// queue: a stop must not wait for long-running commands, it ends them.
    func exec(_ request: CoworkExecRequest) async throws -> AsyncThrowingStream<CoworkExecEvent, any Error> {
        let request = try request.validated()
        return try await lifecycle.run { try await self.launch(request) }
    }

    func stop() async throws {
        try await lifecycle.run { try await self.performStop() }
    }

    func reset() async throws {
        try await lifecycle.run { try await self.performReset() }
    }

    // MARK: - Queued operations

    private func performStart(_ configuration: CoworkVMConfiguration) async throws {
        switch CoworkVMLifecycle.action(current: state(), requested: configuration) {
        case .none:
            return
        case .restart:
            try await performStop()
        case .start:
            break
        }
        try await boot(configuration)
    }

    private func performStop() async throws {
        defer {
            container = nil
            running = nil
        }
        guard let container else { return }
        // Marked before the guest goes down, because the stop is what makes
        // their `wait` return or fail.
        interruptedExecs.formUnion(activeExecs.keys)
        do {
            try await container.stop()
        } catch {
            // The guest may be half down, but the next boot reuses the same
            // container ID and must find its network interface free.
            try? manager?.releaseNetwork(Self.containerID)
            throw error
        }
        try manager?.releaseNetwork(Self.containerID)
    }

    private func performReset() async throws {
        try await performStop()
        if FileManager.default.fileExists(atPath: layout.writableLayer.path) {
            try FileManager.default.removeItem(at: layout.writableLayer)
        }
    }

    private func launch(_ request: CoworkExecRequest) async throws -> AsyncThrowingStream<CoworkExecEvent, any Error> {
        guard let container else { throw CoworkVMError.notRunning }
        execCounter += 1
        let id = execCounter

        let (stream, continuation) = AsyncThrowingStream<CoworkExecEvent, any Error>.makeStream()
        let process = try await container.exec("turbocode-\(id)") { config in
            config.arguments = ["/bin/bash", "-c", request.script]
            config.workingDirectory = request.workingDirectory
            switch request.user {
            case .agent:
                config.user = User(
                    uid: CoworkExecRequest.agentUID,
                    gid: CoworkExecRequest.agentUID,
                    username: "cowork"
                )
                config.environmentVariables = Self.environment(home: "/home/cowork", extra: request.environment)
            case .root:
                config.user = User(uid: 0, gid: 0, username: "root")
                config.environmentVariables = Self.environment(home: "/root", extra: request.environment)
            }
            if let input = request.stdin {
                config.stdin = DataReaderStream(data: input)
            }
            config.stdout = StreamWriter(continuation: continuation, kind: .stdout)
            config.stderr = StreamWriter(continuation: continuation, kind: .stderr)
        }
        do {
            try await process.start()
        } catch {
            try? await process.delete()
            throw error
        }
        activeExecs[id] = process

        // `.cancelled` means the consumer went away (the user pressed Stop or
        // the turn was torn down). Without this the guest process would keep
        // running until its timeout, up to half an hour for `vm_exec`. A
        // normal `finish()` reports `.finished` and kills nothing.
        continuation.onTermination = { termination in
            guard case .cancelled = termination else { return }
            Task { await self.killExec(id) }
        }

        let timeoutSeconds = Int64(max(1, request.timeout.components.seconds))
        Task { await self.supervise(id, process: process, timeoutSeconds: timeoutSeconds, continuation: continuation) }
        return stream
    }

    // MARK: - Exec supervision

    /// Waits for one guest process and ends its stream with exactly one
    /// outcome: exit, timeout, or interruption by a stop or reset.
    private func supervise(
        _ id: Int,
        process: LinuxProcess,
        timeoutSeconds: Int64,
        continuation: AsyncThrowingStream<CoworkExecEvent, any Error>.Continuation
    ) async {
        defer {
            activeExecs[id] = nil
            interruptedExecs.remove(id)
        }
        let outcome: CoworkExecEvent
        do {
            let status = try await process.wait(timeoutInSeconds: timeoutSeconds)
            outcome = .exited(status.exitCode)
        } catch {
            if !interruptedExecs.contains(id) {
                // Containerization reports an expired wait as an error; the
                // process is still alive and must not outlive the request.
                try? await process.kill(.kill)
                _ = try? await process.wait(timeoutInSeconds: 5)
            }
            outcome = .timedOut
        }
        // Checked after the wait whichever way it ended: a stopping guest can
        // make `wait` return a kill status as well as throw.
        if interruptedExecs.contains(id) {
            continuation.finish(throwing: CoworkVMError.interrupted)
            return
        }
        continuation.yield(outcome)
        try? await process.delete()
        continuation.finish()
    }

    private func killExec(_ id: Int) async {
        guard let process = activeExecs[id] else { return }
        try? await process.kill(.kill)
    }

    // MARK: - Boot

    private func boot(_ configuration: CoworkVMConfiguration) async throws {
        let fileManager = FileManager.default
        let kernelURL = layout.kernel(for: descriptor)
        let baseURL = layout.baseRootfs(for: descriptor)
        guard fileManager.fileExists(atPath: kernelURL.path) else {
            throw CoworkVMError.notInstalled("missing kernel \(kernelURL.lastPathComponent)")
        }
        guard fileManager.fileExists(atPath: baseURL.path) else {
            throw CoworkVMError.notInstalled("missing base image \(baseURL.lastPathComponent)")
        }
        let shares = try CoworkMountPlan.shares(for: configuration)
        try fileManager.createDirectory(at: configuration.outbox, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: layout.vmDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: layout.containerDirectory(id: Self.containerID),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: layout.writableLayer.path) {
            let formatter = try EXT4.Formatter(
                FilePath(layout.writableLayer.path),
                minDiskSize: Self.writableLayerBytes
            )
            try formatter.close()
        }

        var manager = try await ContainerManager(
            kernel: Kernel(path: kernelURL, platform: .linuxArm),
            initfsReference: descriptor.initReference,
            root: layout.imageStore,
            network: configuration.networkEnabled ? try VmnetNetwork() : nil
        )
        // pull: false — the installer already fetched the pinned image; the
        // runtime must never contact a registry on its own.
        let image = try await manager.imageStore.get(reference: descriptor.imageReference, pull: false)
        let base = Containerization.Mount.block(
            format: "ext4",
            source: baseURL.path,
            destination: "/",
            options: ["ro"]
        )
        let overlay = Containerization.Mount.block(
            format: "ext4",
            source: layout.writableLayer.path,
            destination: "/",
            options: []
        )

        // A boot that fails after this point has already reserved the
        // container's network interface (and maybe a running guest). The
        // runtime would forget both, and the next boot of the same container
        // ID would fail until the app quits, so a failure releases them first.
        let container: LinuxContainer
        do {
            container = try await createContainer(
                manager: &manager,
                image: image,
                base: base,
                overlay: overlay,
                shares: shares,
                configuration: configuration
            )
            try await container.create()
        } catch {
            try? manager.releaseNetwork(Self.containerID)
            throw error
        }
        do {
            try await container.start()
        } catch {
            try? await container.stop()
            try? manager.releaseNetwork(Self.containerID)
            throw error
        }

        self.manager = manager
        self.container = container
        self.running = configuration
    }

    private func createContainer(
        manager: inout ContainerManager,
        image: Containerization.Image,
        base: Containerization.Mount,
        overlay: Containerization.Mount,
        shares: [CoworkMountPlan.Share],
        configuration: CoworkVMConfiguration
    ) async throws -> LinuxContainer {
        try await manager.create(
            Self.containerID,
            image: image,
            rootfs: base,
            writableLayer: overlay,
            networking: configuration.networkEnabled,
            vm: VMResources(
                cpus: configuration.cpus,
                memoryInBytes: configuration.memoryBytes + VMResources.guestMemoryOverhead
            )
        ) { config in
            config.cpus = configuration.cpus
            config.memoryInBytes = configuration.memoryBytes
            config.hostname = Self.hostname
            config.process.arguments = ["/bin/sleep", "infinity"]
            // Without this entry `sudo` warns "unable to resolve host cowork".
            var hosts = Hosts.default
            hosts.entries.append(Hosts.Entry(ipAddress: "127.0.1.1", hostnames: [Self.hostname]))
            config.hosts = hosts
            for share in shares {
                config.mounts.append(.share(
                    source: share.hostPath,
                    destination: share.guestPath,
                    options: share.readOnly ? ["ro"] : []
                ))
            }
        }
    }

    nonisolated private static func environment(home: String, extra: [String: String]) -> [String] {
        var values = [
            "PATH": "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
            "HOME": home,
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
        ]
        values.merge(extra) { _, new in new }
        return values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }
}

/// Feeds a fixed buffer to a guest process's standard input, then closes it.
private nonisolated struct DataReaderStream: ReaderStream {
    let data: Data

    func stream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            if !data.isEmpty { continuation.yield(data) }
            continuation.finish()
        }
    }
}

/// Forwards guest output into the exec stream as it arrives.
private nonisolated final class StreamWriter: Writer, Sendable {
    enum Kind: Sendable {
        case stdout
        case stderr
    }

    private let continuation: AsyncThrowingStream<CoworkExecEvent, any Error>.Continuation
    private let kind: Kind

    init(continuation: AsyncThrowingStream<CoworkExecEvent, any Error>.Continuation, kind: Kind) {
        self.continuation = continuation
        self.kind = kind
    }

    func write(_ data: Data) throws {
        continuation.yield(kind == .stdout ? .stdout(data) : .stderr(data))
    }

    func close() throws {}
}

// MARK: - Installation

/// `CoworkImageProvisioning` backed by Containerization's image store.
/// Registry access happens only here, and only for the pinned references.
nonisolated struct ContainerizationCoworkProvisioner: CoworkImageProvisioning {
    /// Sparse capacity of the read-only base; the 0.62 image uses ≈1.4 GB.
    static let baseRootfsBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024

    let descriptor: CoworkImageDescriptor
    let layout: CoworkSandboxLayout

    init(descriptor: CoworkImageDescriptor = .current, layout: CoworkSandboxLayout = .init()) {
        self.descriptor = descriptor
        self.layout = layout
    }

    func prepareInitFilesystem() async throws {
        // ContainerManager reads `<store>/initfs.ext4`; the installer deletes
        // it whenever the pinned init reference changes.
        let initPath = layout.imageStore.appendingPathComponent("initfs.ext4")
        guard !FileManager.default.fileExists(atPath: initPath.path) else { return }
        let store = try ImageStore(path: layout.imageStore)
        let initImage = try await store.getInitImage(reference: descriptor.initReference)
        _ = try await initImage.initBlock(at: initPath, for: .linuxArm)
    }

    func pullImage(progress: @escaping @Sendable (Double?) -> Void) async throws {
        let store = try ImageStore(path: layout.imageStore)
        let tracker = ProgressTracker(report: progress)
        _ = try await store.pull(reference: descriptor.imageReference, progress: tracker.handle)
    }

    func unpackBaseRootfs(progress: @escaping @Sendable (Double?) -> Void) async throws {
        let fileManager = FileManager.default
        let destination = layout.baseRootfs(for: descriptor)
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.createDirectory(at: layout.vmDirectory, withIntermediateDirectories: true)
        // Unpack beside the destination and rename, so an interrupted unpack
        // never leaves a base rootfs that looks installed.
        let staging = layout.vmDirectory.appendingPathComponent(".staging-\(UUID().uuidString).ext4")
        defer { try? fileManager.removeItem(at: staging) }
        let store = try ImageStore(path: layout.imageStore)
        let image = try await store.get(reference: descriptor.imageReference, pull: false)
        let tracker = ProgressTracker(report: progress)
        _ = try await EXT4Unpacker(capacityInBytes: Self.baseRootfsBytes)
            .unpack(image, for: .current, at: staging, progress: tracker.handle)
        try Task.checkCancellation()
        try fileManager.moveItem(at: staging, to: destination)
    }
}

/// Folds Containerization progress events into a single 0...1 fraction.
private nonisolated final class ProgressTracker: Sendable {
    private let totals = Mutex<(done: Int64, total: Int64)>((0, 0))
    private let report: @Sendable (Double?) -> Void

    init(report: @escaping @Sendable (Double?) -> Void) {
        self.report = report
    }

    var handle: ProgressHandler {
        { [self] events in
            let fraction: Double? = totals.withLock { totals in
                for event in events {
                    switch event {
                    case .addSize(let size): totals.done += size
                    case .addTotalSize(let size): totals.total += size
                    default: break
                    }
                }
                guard totals.total > 0 else { return nil }
                return min(1, Double(totals.done) / Double(totals.total))
            }
            report(fraction)
        }
    }
}
