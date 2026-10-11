import Foundation
import Testing
@testable import TurboCode

/// Pure contracts of the Cowork VM layer. The Containerization adapter needs
/// the virtualization entitlement and cannot boot inside the test host, so the
/// rules it relies on are tested here and the real VM is validated in the app.
@Suite("Cowork VM runtime contracts")
struct CoworkVMRuntimeTests {
    // MARK: Descriptor

    @Test("The pinned guest is content-addressed")
    func descriptorPinsEveryInputByDigest() {
        let descriptor = CoworkImageDescriptor.current

        #expect(isDigestReference(descriptor.imageReference))
        #expect(isDigestReference(descriptor.initReference))
        #expect(isHexSHA256(descriptor.kernelSHA256))
        #expect(descriptor.kernelSizeBytes > 0)
        #expect(descriptor.kernelURL.scheme == "https")
        #expect(descriptor.kernelURL.path.hasSuffix("/v\(descriptor.version)/vmlinux-arm64"))
        // The init filesystem must match the Containerization version linked
        // by the app (Package.resolved pins 0.49.0 exactly).
        #expect(descriptor.containerizationVersion == "0.49.0")
        #expect(descriptor.imageDigestPrefix.count == 12)
        #expect(isHex(descriptor.imageDigestPrefix))
    }

    // MARK: Layout

    @Test("All VM files live under the Cowork root and are keyed by pins")
    func layoutKeepsFilesUnderRootAndKeyedByDigest() {
        let root = URL(fileURLWithPath: "/tmp/cowork-layout-test", isDirectory: true)
        let layout = CoworkSandboxLayout(root: root)
        let descriptor = CoworkImageDescriptor.current
        let paths = [
            layout.imageStore, layout.vmDirectory, layout.writableLayer, layout.outbox,
            layout.kernel(for: descriptor), layout.baseRootfs(for: descriptor),
            layout.containerDirectory(id: "cowork"),
        ]

        #expect(paths.allSatisfy { $0.path.hasPrefix(root.path + "/") })
        #expect(layout.kernel(for: descriptor).lastPathComponent
            == "vmlinux-\(descriptor.kernelSHA256.prefix(12))")
        #expect(layout.baseRootfs(for: descriptor).lastPathComponent
            == "base-\(descriptor.imageDigestPrefix).ext4")
        #expect(layout.writableLayer.deletingLastPathComponent() == layout.vmDirectory)
    }

    // MARK: Digest

    @Test("FileDigest streams the standard SHA-256")
    func fileDigestMatchesKnownVector() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDigest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)

        #expect(try FileDigest.sha256(at: url)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: Lifecycle

    @Test("Start boots, reuses, or restarts the single VM")
    func lifecycleActions() {
        let base = configuration()
        var changed = base
        changed.inputFolder = URL(fileURLWithPath: "/Users/someone/Other")

        #expect(CoworkVMLifecycle.action(current: .stopped, requested: base) == .start)
        #expect(CoworkVMLifecycle.action(current: .running(base), requested: base) == .none)
        #expect(CoworkVMLifecycle.action(current: .running(base), requested: changed) == .restart)
        var network = base
        network.networkEnabled = false
        #expect(CoworkVMLifecycle.action(current: .running(base), requested: network) == .restart)
    }

    // MARK: Mounts

    @Test("Only the outbox is shared when no input folder is selected")
    func mountPlanWithoutInput() throws {
        let shares = try CoworkMountPlan.shares(for: configuration(), homeDirectory: fakeHome)

        #expect(shares == [.init(hostPath: "/tmp/cowork-outbox", guestPath: "/out", readOnly: false)])
    }

    @Test("The input folder is read-only and the plan never grows beyond two shares")
    func mountPlanWithInput() throws {
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        var config = configuration()
        config.inputFolder = project

        let shares = try CoworkMountPlan.shares(for: config, homeDirectory: fakeHome)

        #expect(shares.count == 2)
        #expect(shares[0].guestPath == "/work" && shares[0].readOnly)
        #expect(shares[1].guestPath == "/out" && !shares[1].readOnly)
    }

    @Test("The disk root and the home folder are never shared, even through a symlink")
    func mountPlanRejectsBroadFolders() throws {
        let home = try temporaryDirectory()
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowork-home-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: home)
        }

        for folder in [URL(fileURLWithPath: "/"), home, link] {
            var config = configuration()
            config.inputFolder = folder
            #expect(throws: CoworkVMError.self) {
                try CoworkMountPlan.shares(for: config, homeDirectory: home)
            }
        }
    }

    // MARK: Exec requests

    @Test("Exec requests are validated before reaching the guest")
    func execRequestValidation() throws {
        #expect(throws: CoworkVMError.self) { try CoworkExecRequest(script: "  \n").validated() }
        #expect(throws: CoworkVMError.self) {
            try CoworkExecRequest(script: "ls", workingDirectory: "relative").validated()
        }
        #expect(throws: CoworkVMError.self) { try CoworkExecRequest(script: "ls", timeout: .zero).validated() }
        #expect(throws: CoworkVMError.self) {
            try CoworkExecRequest(script: "ls", timeout: .seconds(3_601)).validated()
        }

        let valid = try CoworkExecRequest(script: "node -v").validated()
        #expect(valid.user == .agent)
        #expect(valid.workingDirectory == "/home/cowork")
    }

    // MARK: Helpers

    private let fakeHome = URL(fileURLWithPath: "/Users/turbocode-test-home", isDirectory: true)

    private func configuration() -> CoworkVMConfiguration {
        CoworkVMConfiguration(outbox: URL(fileURLWithPath: "/tmp/cowork-outbox", isDirectory: true))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoworkVMRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func isDigestReference(_ reference: String) -> Bool {
        guard let digest = reference.split(separator: "@").last, reference.contains("@sha256:") else {
            return false
        }
        return isHexSHA256(String(digest.dropFirst("sha256:".count)))
    }

    private func isHexSHA256(_ value: String) -> Bool {
        value.count == 64 && isHex(value)
    }

    private func isHex(_ value: String) -> Bool {
        value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
