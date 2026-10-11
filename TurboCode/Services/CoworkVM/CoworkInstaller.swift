import Foundation

/// Visible steps of a Cowork installation, in order.
nonisolated enum CoworkInstallStep: String, Sendable, Equatable, CaseIterable {
    case downloadingKernel
    case preparingInit
    case pullingImage
    case unpackingRootfs
    case verifying

    var title: String {
        switch self {
        case .downloadingKernel: "Downloading kernel"
        case .preparingInit: "Preparing init system"
        case .pullingImage: "Downloading image"
        case .unpackingRootfs: "Preparing disk"
        case .verifying: "Verifying"
        }
    }
}

/// What is installed on disk, written only by the installer. A guest counts
/// as ready only when every pin matches `CoworkImageDescriptor.current` and the
/// image's own smoke test passed for exactly those pins.
nonisolated struct CoworkInstallMarker: Codable, Sendable, Equatable {
    var imageReference: String
    var kernelSHA256: String
    var initReference: String
    var verifiedAt: Date?

    init(descriptor: CoworkImageDescriptor, verifiedAt: Date? = nil) {
        imageReference = descriptor.imageReference
        kernelSHA256 = descriptor.kernelSHA256
        initReference = descriptor.initReference
        self.verifiedAt = verifiedAt
    }
}

nonisolated enum CoworkInstallStatus: Sendable, Equatable {
    case notInstalled
    case ready
}

nonisolated enum CoworkInstallError: LocalizedError, Equatable {
    case kernelDownloadFailed(Int)
    case kernelSizeMismatch
    case kernelDigestMismatch
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .kernelDownloadFailed(let status): "The kernel download failed (HTTP \(status))."
        case .kernelSizeMismatch: "The downloaded kernel has an unexpected size."
        case .kernelDigestMismatch: "The downloaded kernel does not match its pinned SHA-256."
        case .verificationFailed(let detail): "The Cowork VM failed its self-test. \(detail)"
        }
    }
}

/// Installs and verifies the pinned Cowork guest.
///
/// Pure orchestration over injected ports, so every rule here is tested with
/// fakes: the kernel is SHA-256 verified before it is moved into place, a pin
/// change invalidates the derived files built from the old pins, and nothing is
/// reported ready until the image's own smoke test passes in the real VM as
/// uid 1000 with Chromium's sandbox enabled.
nonisolated struct CoworkInstaller: Sendable {
    typealias KernelDownloader = @Sendable (URL) async throws -> (URL, Int)
    typealias StepReporter = @Sendable (CoworkInstallStep, Double?) -> Void

    static let smokeTestPath = "/usr/local/lib/turbocode/smoke-test.sh"
    static let smokeTimeout: Duration = .seconds(300)

    let descriptor: CoworkImageDescriptor
    let layout: CoworkSandboxLayout
    let provisioner: any CoworkImageProvisioning
    let runtime: any CoworkVMRuntime
    let downloadKernel: KernelDownloader

    init(
        descriptor: CoworkImageDescriptor = .current,
        layout: CoworkSandboxLayout = .init(),
        provisioner: any CoworkImageProvisioning,
        runtime: any CoworkVMRuntime,
        downloadKernel: @escaping KernelDownloader = CoworkInstaller.urlSessionDownload
    ) {
        self.descriptor = descriptor
        self.layout = layout
        self.provisioner = provisioner
        self.runtime = runtime
        self.downloadKernel = downloadKernel
    }

    // MARK: Status

    func status() -> CoworkInstallStatus {
        let fileManager = FileManager.default
        guard let marker = readMarker(),
              marker == CoworkInstallMarker(descriptor: descriptor, verifiedAt: marker.verifiedAt),
              marker.verifiedAt != nil,
              fileManager.fileExists(atPath: layout.kernel(for: descriptor).path),
              fileManager.fileExists(atPath: layout.baseRootfs(for: descriptor).path) else {
            return .notInstalled
        }
        return .ready
    }

    // MARK: Install

    /// Returns the smoke-test output on success.
    func install(
        configuration: CoworkVMConfiguration,
        report: @escaping StepReporter
    ) async throws -> String {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try invalidateStaleArtifacts()

        report(.downloadingKernel, nil)
        try await installKernel()
        try Task.checkCancellation()

        report(.preparingInit, nil)
        try await provisioner.prepareInitFilesystem()
        try Task.checkCancellation()

        report(.pullingImage, nil)
        try await provisioner.pullImage { report(.pullingImage, $0) }
        try Task.checkCancellation()

        report(.unpackingRootfs, nil)
        try await provisioner.unpackBaseRootfs { report(.unpackingRootfs, $0) }
        try Task.checkCancellation()
        try writeMarker(CoworkInstallMarker(descriptor: descriptor))

        report(.verifying, nil)
        let output = try await verify(configuration: configuration)
        try writeMarker(CoworkInstallMarker(descriptor: descriptor, verifiedAt: .now))
        return output
    }

    /// Removes every Cowork file. The caller must have stopped the VM.
    func uninstall() throws {
        if FileManager.default.fileExists(atPath: layout.root.path) {
            try FileManager.default.removeItem(at: layout.root)
        }
    }

    // MARK: Steps

    /// A different image means the writable layer was built on another base
    /// and the old base is dead weight; a different init pin means the cached
    /// init filesystem is stale. Both are removed before installing.
    private func invalidateStaleArtifacts() throws {
        guard let marker = readMarker() else { return }
        let fileManager = FileManager.default
        if marker.imageReference != descriptor.imageReference {
            for name in (try? fileManager.contentsOfDirectory(atPath: layout.vmDirectory.path)) ?? []
            where name.hasPrefix("base-") || name == layout.writableLayer.lastPathComponent {
                try fileManager.removeItem(at: layout.vmDirectory.appendingPathComponent(name))
            }
        }
        if marker.initReference != descriptor.initReference {
            let initPath = layout.imageStore.appendingPathComponent("initfs.ext4")
            if fileManager.fileExists(atPath: initPath.path) {
                try fileManager.removeItem(at: initPath)
            }
        }
    }

    private func installKernel() async throws {
        let fileManager = FileManager.default
        let destination = layout.kernel(for: descriptor)
        if fileManager.fileExists(atPath: destination.path),
           (try? FileDigest.sha256(at: destination)) == descriptor.kernelSHA256 {
            return
        }
        let (downloaded, status) = try await downloadKernel(descriptor.kernelURL)
        defer { try? fileManager.removeItem(at: downloaded) }
        guard status == 200 else { throw CoworkInstallError.kernelDownloadFailed(status) }
        let size = (try fileManager.attributesOfItem(atPath: downloaded.path)[.size] as? NSNumber)?.int64Value
        guard size == descriptor.kernelSizeBytes else { throw CoworkInstallError.kernelSizeMismatch }
        guard try FileDigest.sha256(at: downloaded) == descriptor.kernelSHA256 else {
            throw CoworkInstallError.kernelDigestMismatch
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: downloaded, to: destination)
    }

    /// Boots the guest without any host input folder and runs the smoke test
    /// shipped inside the image. ALLOW_NO_SANDBOX is never set: in the real VM
    /// Chromium must render with its sandbox on.
    private func verify(configuration: CoworkVMConfiguration) async throws -> String {
        var configuration = configuration
        configuration.inputFolder = nil
        try await runtime.start(configuration)
        do {
            let stream = try await runtime.exec(CoworkExecRequest(
                script: "SMOKE_OUT=/tmp/turbocode-smoke \(Self.smokeTestPath)",
                timeout: Self.smokeTimeout
            ))
            var output = Data()
            var exitCode: Int32?
            var timedOut = false
            for try await event in stream {
                switch event {
                case .stdout(let data), .stderr(let data): output.append(data)
                case .exited(let code): exitCode = code
                case .timedOut: timedOut = true
                }
            }
            try await runtime.stop()
            let text = String(decoding: output, as: UTF8.self)
            guard !timedOut, exitCode == 0 else {
                let lastLines = text.split(separator: "\n").suffix(4).joined(separator: "\n")
                throw CoworkInstallError.verificationFailed(
                    timedOut ? "It timed out." : "Exit code \(exitCode.map(String.init) ?? "unknown").\n\(lastLines)"
                )
            }
            return text
        } catch {
            try? await runtime.stop()
            throw error
        }
    }

    // MARK: Marker

    private var markerURL: URL { layout.root.appendingPathComponent("installed.json") }

    func readMarker() -> CoworkInstallMarker? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(CoworkInstallMarker.self, from: data)
    }

    private func writeMarker(_ marker: CoworkInstallMarker) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: markerURL, options: .atomic)
    }

    // MARK: Default download

    static let urlSessionDownload: KernelDownloader = { url in
        let (temporary, response) = try await URLSession.shared.download(from: url)
        // URLSession deletes its temporary file once this call returns, so the
        // kernel moves to a location the installer owns first.
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent("turbocode-kernel-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: temporary, to: owned)
        return (owned, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
