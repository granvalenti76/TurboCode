import Foundation
import Darwin

/// Runs the unchanged shell argv in an invocation-owned process group. The
/// leader stays waitable until cleanup finishes, so its PID cannot be reused
/// while we signal the group. No process discovered by name is ever signalled.
nonisolated enum BashProcessRunner {
    struct Result: Sendable {
        let exitCode: Int32?
        let timedOut: Bool
        let cancelled: Bool
        let cleanupComplete: Bool
        let error: String?

        var canRerun: Bool {
            exitCode != nil && !timedOut && !cancelled && cleanupComplete && error == nil
        }
    }

    static func run(
        executable: String, arguments: [String], environment: [String: String],
        directory: String, stdout: Int32, stderr: Int32, timeout: Duration
    ) async -> Result {
        guard !Task.isCancelled else {
            return Result(exitCode: nil, timedOut: false, cancelled: true, cleanupComplete: true, error: nil)
        }
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        // An independent group is set atomically at spawn; setpgid after run()
        // would race short-lived shells and their background children.
        let setup = [
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawn_file_actions_addchdir(&actions, directory),
            posix_spawn_file_actions_addinherit_np(&actions, STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO)
        ]
        if let failure = setup.first(where: { $0 != 0 }) {
            return failureResult("Unable to prepare command: \(String(cString: strerror(failure)))")
        }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            env.forEach { free($0) }
        }
        var pid: pid_t = 0
        guard !Task.isCancelled else {
            return Result(exitCode: nil, timedOut: false, cancelled: true, cleanupComplete: true, error: nil)
        }
        let launched = argv.withUnsafeBufferPointer { argv in
            env.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress!, env.baseAddress!)
            }
        }
        guard launched == 0 else {
            return failureResult("Error launching command: \(String(cString: strerror(launched)))")
        }

        let deadline = ContinuousClock.now + timeout
        var timedOut = false
        var cancelled = false
        var waitError: String?
        while true {
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 {
                if errno == EINTR { continue }
                waitError = "Unable to observe command termination."
                break
            }
            if info.si_pid == pid { break }
            cancelled = Task.isCancelled
            timedOut = ContinuousClock.now >= deadline
            if cancelled || timedOut { break }
            await pause()
        }

        // Ordinary noninteractive shell children inherit this group. Cleanup
        // also runs after a successful shell exit: background work must not
        // overlap a complete replay. Deliberately detached sessions are outside
        // this group contract; this is not a general process supervisor.
        if liveGroupMembers(pid) != false {
            kill(-pid, SIGTERM)
            let grace = ContinuousClock.now + .milliseconds(200)
            while liveGroupMembers(pid) != false && ContinuousClock.now < grace {
                await pause()
            }
            if liveGroupMembers(pid) != false { kill(-pid, SIGKILL) }
        }
        let cleanupDeadline = ContinuousClock.now + .seconds(1)
        while liveGroupMembers(pid) != false && ContinuousClock.now < cleanupDeadline {
            await pause()
        }
        let cleanupComplete = liveGroupMembers(pid) == false
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        if reaped == 0 {
            // A process stuck in the kernel must not stall the tool or be
            // retried. Retain ownership only to reap it when it finally exits.
            Task.detached { [pid] in
                var status: Int32 = 0
                while waitpid(pid, &status, WNOHANG) == 0 { await pause() }
            }
        }
        let exitCode: Int32? = reaped == pid
            ? ((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
            : nil
        return Result(
            exitCode: exitCode, timedOut: timedOut,
            cancelled: cancelled || Task.isCancelled,
            cleanupComplete: cleanupComplete && reaped == pid, error: waitError
        )
    }

    /// A non-cancellable, short suspension keeps cleanup responsive without
    /// spinning on an already-cancelled Task.sleep or blocking the UI executor.
    static func pause(milliseconds: Int = 25) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }

    private static func failureResult(_ error: String) -> Result {
        Result(exitCode: nil, timedOut: false, cancelled: false, cleanupComplete: true, error: error)
    }

    /// nil means the group cannot be inspected: fail closed before any retry.
    /// Ignore zombies; they cannot produce effects and are reaped separately.
    private static func liveGroupMembers(_ group: pid_t) -> Bool? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size < 4_000_000 else { return nil }
        let stride = MemoryLayout<kinfo_proc>.stride
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = entries.count * stride
        let result = entries.withUnsafeMutableBytes { bytes in
            sysctl(&mib, 4, bytes.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return entries.prefix(size / stride).contains { $0.kp_proc.p_stat != SZOMB }
    }
}
