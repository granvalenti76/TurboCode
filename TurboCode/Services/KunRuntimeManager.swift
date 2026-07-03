import Foundation

// MARK: - KunRuntimeManager — manages the Kun Node.js runtime process

/// Stub for launching, monitoring, and stopping the `kun serve` process.
/// Will be wired to ChatStore.runtimeStatus when the LLM package is integrated.
@MainActor
public final class KunRuntimeManager {
    public static let shared = KunRuntimeManager()

    private var process: Process?
    private let healthURL = URL(string: "http://127.0.0.1:18899/health")!
    private let apiURL = URL(string: "http://127.0.0.1:18788")!

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    public func start(kunPath: String) async throws {
        guard !isRunning else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", kunPath, "serve", "--port", "18788"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        self.process = process

        // Wait for health check
        try await waitForHealth(timeout: 10)
    }

    public func stop() {
        process?.terminate()
        process = nil
    }

    public func restart(kunPath: String) async throws {
        stop()
        try await start(kunPath: kunPath)
    }

    // MARK: - Health Check

    private func waitForHealth(timeout: TimeInterval) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            if try await checkHealth() { return }
            try await Task.sleep(for: .milliseconds(500))
        }

        throw RuntimeError.healthCheckTimeout
    }

    private func checkHealth() async throws -> Bool {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 2

        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }

        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - Errors

    public enum RuntimeError: LocalizedError {
        case healthCheckTimeout
        case processLaunchFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .healthCheckTimeout:
                return "Kun runtime did not become healthy within the timeout"
            case .processLaunchFailed(let error):
                return "Failed to launch Kun runtime: \(error.localizedDescription)"
            }
        }
    }
}
