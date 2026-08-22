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
        #expect(relativePaths.contains("Runtime/RuntimeContracts.swift"))
        #expect(relativePaths.contains("Runtime/AgentRuntime.swift"))
    }

    /// Phase A permits the store's separate post-turn title helper to create a
    /// short-lived session until that utility moves in the next slice. These
    /// tokens specifically guard active conversation-session ownership: the
    /// observable store must never regain the runtime, relay, transcript port,
    /// or rebuild authority removed by the 0.3.7 boundary.
    @Test("Observable model configuration owns no active provider session")
    func modelRuntimeStoreOwnsNoActiveProviderSession() throws {
        let storeURL = Self.repositoryRoot
            .appendingPathComponent("TurboCode/Stores/ModelRuntimeStore.swift")
        let source = try String(contentsOf: storeURL, encoding: .utf8)
        let forbiddenTokens = [
            "let foundationModelsRuntime",
            "var activeReasoningStreamRelay",
            "var transcript: Transcript",
            "func rebuildSession("
        ]

        for token in forbiddenTokens {
            #expect(!source.contains(token))
        }
    }

    private func coreSwiftSourceURLs() throws -> [URL] {
        let coreURL = Self.coreURL
        guard let enumerator = FileManager.default.enumerator(
            at: coreURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw TurboCodeCoreArchitectureTestError.cannotEnumerate(coreURL)
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
