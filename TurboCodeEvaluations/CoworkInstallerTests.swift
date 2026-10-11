import Foundation
import Synchronization
import Testing
@testable import TurboCode

/// Installation rules for the Cowork guest, exercised with fake ports. The real
/// VM path is validated in the signed app; these tests pin the guarantees:
/// verified kernels only, stale artifacts invalidated, and nothing "ready"
/// until the image's own smoke test passes.
@Suite("Cowork installer")
struct CoworkInstallerTests {
    @Test("A verified install reports every step and becomes ready")
    func installBecomesReady() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let steps = Mutex<[CoworkInstallStep]>([])
        #expect(fixture.installer().status() == .notInstalled)

        let output = try await fixture.installer().install(configuration: fixture.configuration) { step, _ in
            steps.withLock { if $0.last != step { $0.append(step) } }
        }

        #expect(output.contains("all checks passed"))
        #expect(steps.withLock { $0 } == CoworkInstallStep.allCases)
        #expect(fixture.installer().status() == .ready)
        #expect(fixture.installer().readMarker()?.verifiedAt != nil)
        #expect(try FileDigest.sha256(at: fixture.layout.kernel(for: fixture.descriptor))
            == fixture.descriptor.kernelSHA256)
        #expect(await fixture.runtime.state() == .stopped)
    }

    @Test("Verification runs the image smoke test as the agent with the sandbox required")
    func verificationUsesImageSmokeTest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var configuration = fixture.configuration
        configuration.inputFolder = fixture.root

        _ = try await fixture.installer().install(configuration: configuration) { _, _ in }

        let request = try #require(await fixture.runtime.requests.first)
        #expect(request.user == .agent)
        #expect(request.script.contains(CoworkInstaller.smokeTestPath))
        #expect(!request.script.contains("ALLOW_NO_SANDBOX"))
        // The self-test never sees a host folder.
        #expect(await fixture.runtime.startedConfigurations.first?.inputFolder == nil)
    }

    @Test("A kernel with the wrong digest is never installed")
    func kernelDigestMismatchFails() async throws {
        let fixture = try Fixture(kernelBytes: Data("tampered".utf8))
        defer { fixture.cleanUp() }

        await #expect(throws: CoworkInstallError.self) {
            _ = try await fixture.installer().install(configuration: fixture.configuration) { _, _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.kernel(for: fixture.descriptor).path))
        #expect(fixture.installer().status() == .notInstalled)
    }

    @Test("A failing self-test leaves Cowork not ready and the VM stopped")
    func failedSelfTestIsNotReady() async throws {
        let fixture = try Fixture(smokeExitCode: 1)
        defer { fixture.cleanUp() }

        await #expect(throws: CoworkInstallError.self) {
            _ = try await fixture.installer().install(configuration: fixture.configuration) { _, _ in }
        }
        #expect(fixture.installer().status() == .notInstalled)
        #expect(fixture.installer().readMarker()?.verifiedAt == nil)
        #expect(await fixture.runtime.state() == .stopped)
    }

    @Test("A new image pin discards the old base and the writable layer")
    func imageUpgradeInvalidatesDerivedFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: fixture.layout.vmDirectory, withIntermediateDirectories: true)
        let oldBase = fixture.layout.vmDirectory.appendingPathComponent("base-0123456789ab.ext4")
        try Data().write(to: oldBase)
        try Data("agent changes".utf8).write(to: fixture.layout.writableLayer)
        var oldMarker = CoworkInstallMarker(descriptor: fixture.descriptor, verifiedAt: .now)
        oldMarker.imageReference = "ghcr.io/example/old@sha256:" + String(repeating: "0", count: 64)
        try JSONEncoder().encode(oldMarker).write(to: fixture.root.appendingPathComponent("installed.json"))
        #expect(fixture.installer().status() == .notInstalled)

        _ = try await fixture.installer().install(configuration: fixture.configuration) { _, _ in }

        #expect(!fileManager.fileExists(atPath: oldBase.path))
        #expect(!fileManager.fileExists(atPath: fixture.layout.writableLayer.path))
        #expect(fileManager.fileExists(atPath: fixture.layout.baseRootfs(for: fixture.descriptor).path))
        #expect(fixture.installer().status() == .ready)
    }

    @Test("Uninstall removes every Cowork file")
    func uninstallRemovesRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.installer().install(configuration: fixture.configuration) { _, _ in }

        try fixture.installer().uninstall()

        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
        #expect(fixture.installer().status() == .notInstalled)
    }
}

// MARK: - Fixture

private struct Fixture {
    let root: URL
    let layout: CoworkSandboxLayout
    let descriptor: CoworkImageDescriptor
    let runtime: FakeCoworkRuntime
    let kernelBytes: Data
    let configuration: CoworkVMConfiguration

    init(kernelBytes: Data = Data("kernel".utf8), smokeExitCode: Int32 = 0) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoworkInstallerTests-\(UUID().uuidString)", isDirectory: true)
        layout = CoworkSandboxLayout(root: root)
        let expected = Data("kernel".utf8)
        let digestFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try expected.write(to: digestFile)
        defer { try? FileManager.default.removeItem(at: digestFile) }
        descriptor = CoworkImageDescriptor(
            version: "0.0.0-test",
            imageReference: "ghcr.io/example/cowork@sha256:" + String(repeating: "a", count: 64),
            kernelURL: URL(string: "https://example.invalid/v0.0.0-test/vmlinux-arm64")!,
            kernelSHA256: try FileDigest.sha256(at: digestFile),
            kernelSizeBytes: Int64(expected.count),
            kernelVersion: "6.18.5",
            initReference: "ghcr.io/example/vminit@sha256:" + String(repeating: "b", count: 64),
            containerizationVersion: "0.49.0"
        )
        runtime = FakeCoworkRuntime(smokeExitCode: smokeExitCode)
        self.kernelBytes = kernelBytes
        configuration = CoworkVMConfiguration(outbox: layout.outbox)
    }

    func installer() -> CoworkInstaller {
        let bytes = kernelBytes
        return CoworkInstaller(
            descriptor: descriptor,
            layout: layout,
            provisioner: FakeProvisioner(base: layout.baseRootfs(for: descriptor)),
            runtime: runtime,
            downloadKernel: { _ in
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try bytes.write(to: url)
                return (url, 200)
            }
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct FakeProvisioner: CoworkImageProvisioning {
    let base: URL

    func prepareInitFilesystem() async throws {}

    func pullImage(progress: @escaping @Sendable (Double?) -> Void) async throws {
        progress(0.5)
        progress(1)
    }

    func unpackBaseRootfs(progress: @escaping @Sendable (Double?) -> Void) async throws {
        try FileManager.default.createDirectory(
            at: base.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: base)
        progress(1)
    }
}

private actor FakeCoworkRuntime: CoworkVMRuntime {
    private let smokeExitCode: Int32
    private var running: CoworkVMConfiguration?
    private(set) var requests: [CoworkExecRequest] = []
    private(set) var startedConfigurations: [CoworkVMConfiguration] = []

    init(smokeExitCode: Int32) {
        self.smokeExitCode = smokeExitCode
    }

    func start(_ configuration: CoworkVMConfiguration) async throws {
        startedConfigurations.append(configuration)
        running = configuration
    }

    func exec(_ request: CoworkExecRequest) async throws -> AsyncThrowingStream<CoworkExecEvent, any Error> {
        requests.append(try request.validated())
        let code = smokeExitCode
        return AsyncThrowingStream { continuation in
            continuation.yield(.stdout(Data("PASS chromium render: JavaScript executed with sandbox ON\n".utf8)))
            continuation.yield(.stdout(Data((code == 0 ? "all checks passed\n" : "1 check(s) failed\n").utf8)))
            continuation.yield(.exited(code))
            continuation.finish()
        }
    }

    func stop() async throws {
        running = nil
    }

    func reset() async throws {
        running = nil
    }

    func state() async -> CoworkVMState {
        running.map(CoworkVMState.running) ?? .stopped
    }
}
