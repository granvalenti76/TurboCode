import Foundation

/// Host-side files of the single Cowork VM, all under `~/.turbocode/cowork/`.
///
/// Nothing here is shared with the guest except the read-only input folder and
/// the outbox, which `CoworkMountPlan` decides. Removing `root` uninstalls
/// Cowork completely; removing only `writableLayer` resets the VM.
nonisolated struct CoworkSandboxLayout: Sendable, Equatable {
    let root: URL

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".turbocode/cowork", isDirectory: true)
    ) {
        self.root = root
    }

    /// Containerization content store: OCI blobs, references, init filesystem.
    var imageStore: URL { root.appendingPathComponent("store", isDirectory: true) }

    var vmDirectory: URL { root.appendingPathComponent("vm", isDirectory: true) }

    /// Persistent overlay holding every change the agent makes in the guest.
    /// Deleting it is the "Reset VM" action; the base image stays installed.
    var writableLayer: URL { vmDirectory.appendingPathComponent("writable.ext4") }

    /// Parent of every session outbox. Files placed directly here predate
    /// per-session outboxes and remain reachable from Finder.
    var outbox: URL { root.appendingPathComponent("outbox", isDirectory: true) }

    /// The host folder a session's guest sees at `/out`. Each session gets its
    /// own, so one session can never export another session's deliverables.
    func outbox(forSession sessionID: String) -> URL {
        outbox.appendingPathComponent(CoworkSessionContext.safeComponent(sessionID), isDirectory: true)
    }

    /// Kernel files are named by digest so a new pin never overwrites the
    /// kernel a running VM booted from.
    func kernel(for descriptor: CoworkImageDescriptor) -> URL {
        root.appendingPathComponent("kernel", isDirectory: true)
            .appendingPathComponent("vmlinux-\(descriptor.kernelSHA256.prefix(12))")
    }

    /// Read-only lower layer unpacked once from the pinned image.
    func baseRootfs(for descriptor: CoworkImageDescriptor) -> URL {
        vmDirectory.appendingPathComponent("base-\(descriptor.imageDigestPrefix).ext4")
    }

    /// Per-container files Containerization expects (boot log).
    func containerDirectory(id: String) -> URL {
        imageStore.appendingPathComponent("containers", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }
}
