import Foundation
import Testing
@testable import TurboCode

@Suite("TurboCodeCore architecture boundary")
struct TurboCodeCoreArchitectureTests {
    /// Until TurboCodeCore becomes a separate target, the compiler cannot stop
    /// a same-module source file from reaching back into application state.
    /// This source-level tripwire makes that temporary weakness explicit and
    /// fails as soon as a forbidden UI, store, or concrete-provider dependency
    /// crosses the staged library boundary.
    @Test("Core Swift sources remain application and presentation neutral")
    func coreSourcesRemainApplicationNeutral() throws {
        let sourceURLs = try coreSwiftSourceURLs()
        #expect(!sourceURLs.isEmpty)

        let forbiddenTokens = [
            "import SwiftUI",
            "import AppKit",
            "import Observation",
            "@Observable",
            "@MainActor",
            "ChatStore",
            "ChatResponseCoordinator",
            "ModelRuntimeStore",
            "WorkspaceStore",
            "LanguageModelSession",
            "ReasoningStreamRelay",
            "NativeBackendSession",
            "CodexBackendSession"
        ]

        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for token in forbiddenTokens {
                #expect(!source.contains(token))
            }
        }
    }

    @Test("Domain and runtime ownership live inside the staged core boundary")
    func coreOwnsRuntimeAndBackendIdentity() throws {
        let relativePaths = try coreSwiftSourceURLs().map(coreRelativePath)

        #expect(relativePaths.contains("Domain/ModelBackend.swift"))
        #expect(relativePaths.contains("Domain/ReasoningEffort.swift"))
        #expect(relativePaths.contains("Domain/ToolArtifact.swift"))
        #expect(relativePaths.contains("Runtime/RuntimeContracts.swift"))
        #expect(relativePaths.contains("Runtime/AgentRuntime.swift"))
    }

    /// The configuration facade may emit immutable selections, but concrete
    /// providers, sessions, transcript types, and worker factories must remain
    /// behind non-observable application services.
    @Test("Observable model store owns configuration only")
    func modelRuntimeStoreOwnsConfigurationOnly() throws {
        let storeURL = Self.repositoryRoot
            .appendingPathComponent("TurboCode/Stores/ModelRuntimeStore.swift")
        let source = try String(contentsOf: storeURL, encoding: .utf8)
        let forbiddenTokens = [
            "import FoundationModels",
            "let foundationModelsRuntime",
            "var activeReasoningStreamRelay",
            "var transcript: Transcript",
            "func rebuildSession(",
            "LanguageModelSession(",
            "SystemLanguageModel.",
            "ProviderLanguageModel(",
            "ModelSessionFactory.",
            "ConfiguredAgentTaskInvoker",
            "ContextOptions."
        ]

        for token in forbiddenTokens {
            #expect(!source.contains(token))
        }
    }

    /// Structured widget data must be part of the accepted tool completion.
    /// A second presentation callback would escape the runtime TurnID gate and
    /// could project stale output after cancellation or a thread switch.
    @Test("LLM adapters expose no parallel widget presentation channel")
    func llmAdaptersHaveNoWidgetSideChannel() throws {
        let relativePaths = [
            "TurboCode/Services/Chat/LLMRuntime.swift",
            "TurboCode/Stores/CodexRuntimeStore.swift",
            "TurboCode/Stores/ChatResponseCoordinator.swift"
        ]
        let forbiddenTokens = [
            "presentationRequested",
            "CodexToolPresentation",
            "ToolPresentationRouter"
        ]

        for relativePath in relativePaths {
            let sourceURL = Self.repositoryRoot.appendingPathComponent(relativePath)
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for token in forbiddenTokens {
                #expect(!source.contains(token))
            }
        }
    }

    /// Tools produce domain results; only the owning runtime completion may
    /// project them into observable application state. Keeping this tripwire at
    /// the source boundary prevents a convenience regression to the old global
    /// facade while the tools still compile in the application target.
    @Test("Tools do not reach the ChatStore singleton")
    func toolsDoNotReachChatStoreSingleton() throws {
        let toolsURL = Self.repositoryRoot
            .appendingPathComponent("TurboCode/Tools", isDirectory: true)
        let sourceURLs = try swiftSourceURLs(at: toolsURL)
        #expect(!sourceURLs.isEmpty)

        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            #expect(!source.contains("ChatStore.shared"))
        }
    }

    /// The observable façade should forward its compatibility surface to a
    /// non-observable composition root instead of rebuilding the dependency
    /// graph whenever that façade evolves.
    @Test("ChatStore delegates construction to the application assembly")
    func chatStoreDelegatesConstructionToAssembly() throws {
        let chatStoreSource = try source(at: "TurboCode/Stores/ChatStore.swift")
        let assemblySource = try source(
            at: "TurboCode/Stores/ChatApplicationAssembly.swift"
        )

        #expect(chatStoreSource.contains("private let assembly: ChatApplicationAssembly"))
        #expect(chatStoreSource.contains("self.assembly = ChatApplicationAssembly("))
        #expect(assemblySource.contains("final class ChatApplicationAssembly"))
        #expect(!assemblySource.contains("@Observable"))
    }

    /// The Xcode target defaults unannotated declarations to MainActor. These
    /// source guards therefore protect the explicit opt-out that keeps native
    /// provider streaming and lifecycle ownership away from the UI executor.
    @Test("Native execution ownership remains outside MainActor")
    func nativeExecutionOwnershipRemainsOffMainActor() throws {
        let runtimeSource = try source(
            at: "TurboCode/Services/Chat/LLMRuntime.swift"
        )
        let nativeSource = try source(
            at: "TurboCode/Services/Chat/NativeResponseRunner.swift"
        )
        let sessionSource = try source(
            at: "TurboCode/Services/Chat/FoundationModelsSessionRuntime.swift"
        )

        #expect(runtimeSource.contains("actor LLMRuntime"))
        #expect(sessionSource.contains("actor FoundationModelsSessionRuntime"))
        #expect(nativeSource.contains("nonisolated final class NativeResponseRunner"))
        #expect(nativeSource.contains("actor NativeBackendSession"))
        #expect(!nativeSource.contains("Task { @MainActor in"))
    }

    /// Codex transport state must remain usable without constructing the
    /// observable application facade. Source tripwires complement actor tests
    /// until these files become separate Swift targets.
    @Test("Codex execution engine is independent from its UI facade")
    func codexExecutionEngineIsIndependentFromUIFacade() throws {
        let storeSource = try source(at: "TurboCode/Stores/CodexRuntimeStore.swift")
        let engineSource = try source(
            at: "TurboCode/Services/Codex/CodexExecutionEngine.swift"
        )
        let adapterSource = try source(
            at: "TurboCode/Services/Codex/CodexBackendSession.swift"
        )

        let forbiddenStoreOwnership = [
            "private let client:",
            "threadIDs",
            "threadConfigurations",
            "tokenUsageByThread",
            "importedContexts",
            "handoffBoundaryBlockIDs",
            "approvals:",
            "func runTurn("
        ]
        for token in forbiddenStoreOwnership {
            #expect(!storeSource.contains(token))
        }

        let forbiddenEngineDependencies = [
            "import AppKit",
            "import SwiftUI",
            "import Observation",
            "@Observable",
            "@MainActor",
            "CodexRuntimeStore",
            "UserDefaults.",
            "NSWorkspace."
        ]
        for token in forbiddenEngineDependencies {
            #expect(!engineSource.contains(token))
        }

        #expect(engineSource.contains("actor CodexExecutionEngine"))
        #expect(adapterSource.contains("actor CodexBackendSession"))
        #expect(!adapterSource.contains("Task { @MainActor in"))
    }

    private func source(at relativePath: String) throws -> String {
        try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func coreSwiftSourceURLs() throws -> [URL] {
        try swiftSourceURLs(at: Self.coreURL)
    }

    private func swiftSourceURLs(at directoryURL: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw TurboCodeCoreArchitectureTestError.cannotEnumerate(directoryURL)
        }

        var sourceURLs: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            sourceURLs.append(url)
        }
        return sourceURLs.sorted { $0.path < $1.path }
    }

    private func coreRelativePath(_ sourceURL: URL) -> String {
        let prefix = Self.coreURL.path + "/"
        guard sourceURL.path.hasPrefix(prefix) else { return sourceURL.path }
        return String(sourceURL.path.dropFirst(prefix.count))
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let coreURL = repositoryRoot
        .appendingPathComponent("TurboCode/TurboCodeCore", isDirectory: true)
}

private enum TurboCodeCoreArchitectureTestError: Error {
    case cannotEnumerate(URL)
}
