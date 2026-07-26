import Foundation
import Testing
@testable import TurboCode

private let localBenchmarkMarkerURL = URL(
    fileURLWithPath: "/tmp/TurboCodeLocalBenchmark.json"
)

private struct LocalBenchmarkConnection: Codable {
    let url: String
    let modelName: String
}

// Decode the one-shot request before either serialized domain benchmark
// consumes it, so both SwiftPM and Xcode use the same endpoint and model.
private let localBenchmarkConnection = try? JSONDecoder().decode(
    LocalBenchmarkConnection.self,
    from: Data(contentsOf: localBenchmarkMarkerURL)
)
private let runsLocalBenchmark =
    ProcessInfo.processInfo.environment["TURBOCODE_RUN_LOCAL_BENCHMARK"] == "1"
    || localBenchmarkConnection != nil

/// Opt-in because it requires a running OpenAI-compatible local server and is
/// intentionally slower than deterministic unit tests. This closes the gap
/// between schema-level coverage and the behavior of an actual small model.
@MainActor
@Suite("Local agent benchmark", .serialized)
struct AgentBenchmarkLiveTests {
    @Test(
        "Local model completes an inspect-edit-build SwiftPM loop",
        .enabled(if: runsLocalBenchmark)
    )
    func localModelCompletesSwiftPackageLoop() async {
        // A marker is a one-shot request so normal test runs immediately
        // return to their deterministic, offline behavior.
        try? FileManager.default.removeItem(at: localBenchmarkMarkerURL)
        let result = await AgentBenchmarkRunner.run(
            backend: .llamaServer,
            model: localModel,
            reasoningLevel: nil
        )

        #expect(result.succeeded, Comment(rawValue: result.detail))
    }

    @Test(
        "Local model completes an inspect-edit-build Xcode loop",
        .enabled(if: runsLocalBenchmark)
    )
    func localModelCompletesXcodeProjectLoop() async {
        try? FileManager.default.removeItem(at: localBenchmarkMarkerURL)
        let result = await AgentBenchmarkRunner.run(
            backend: .llamaServer,
            model: localModel,
            reasoningLevel: nil,
            kind: .xcodeProject
        )

        #expect(result.succeeded, Comment(rawValue: result.detail))
    }

    private var localModel: ProviderLanguageModel {
        let environment = ProcessInfo.processInfo.environment
        let configuration = RemoteModelConfig(
            id: "live-local-benchmark",
            name: "Live local benchmark",
            url: localBenchmarkConnection?.url
                ?? environment["TURBOCODE_LOCAL_MODEL_URL"]
                ?? "http://127.0.0.1:8080/v1",
            modelName: localBenchmarkConnection?.modelName
                ?? environment["TURBOCODE_LOCAL_MODEL_NAME"]
                ?? "local-model",
            temperature: 0,
            role: .local,
            reasoningTransport: .none,
            supportsReasoning: false,
            supportsGuidedGeneration: true,
            contextWindowTokens: 25_088,
            repositoryMap: .compact
        )
        return ProviderLanguageModel(configuration: configuration, apiKey: nil)
    }
}
