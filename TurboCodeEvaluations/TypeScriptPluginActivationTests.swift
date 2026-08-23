import Foundation
import Testing
@testable import TurboCode

@Suite("Third-party plugin activation policy")
struct TypeScriptPluginActivationTests {
    @Test("Third-party plugins are disabled when decoding an older agent config")
    func olderConfigurationKeepsPluginsDisabled() throws {
        let data = Data("""
        {"schemaVersion":1,"experimental":{"safariMCPEnabled":true}}
        """.utf8)

        let config = try JSONDecoder().decode(AgentTuningConfig.self, from: data)

        #expect(config.experimental.safariMCPEnabled)
        #expect(!config.experimental.thirdPartyPluginsEnabled)
    }

    @Test("Disabled activation never starts a plugin process")
    func disabledActivationIsRejected() async throws {
        let manifest = TypeScriptPluginManifest(
            id: "policy-plugin",
            name: "Policy Plugin",
            version: "0.1.0",
            entrypoint: "index.js",
            tools: [
                TypeScriptPluginToolManifest(
                    name: "echo",
                    description: "Echo",
                    inputSchema: .object(["type": .string("object")])
                )
            ]
        )
        let descriptor = TypeScriptPluginDescriptor(
            manifest: manifest,
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("policy-plugin", isDirectory: true)
        )
        let store = TypeScriptPluginActivationStore()

        await #expect(throws: TypeScriptPluginActivationError.disabled) {
            try await store.activate(descriptor)
        }
        #expect(await !store.isEnabled())
        #expect(await store.activeTools().isEmpty)

        await store.setEnabled(true)
        #expect(await store.isEnabled())
        await store.setEnabled(false)
        #expect(await !store.isEnabled())
    }

    @Test("Profile plugin IDs stay separate from built-in capabilities")
    func profileSeparatesPluginIDs() throws {
        let profile = UserDynamicProfile(
            name: "Plugin profile",
            baseModelID: .llama,
            toolIDs: [ToolCapabilityID.readFile.rawValue],
            pluginToolIDs: ["helper/echo", "helper/echo", "invalid"]
        )

        #expect(profile.resolvedToolIDs == [.readFile])
        #expect(profile.resolvedPluginToolIDs.map(\.rawValue) == ["helper/echo"])

        let restored = try JSONDecoder().decode(
            UserDynamicProfile.self,
            from: JSONEncoder().encode(profile)
        )
        #expect(restored.pluginToolIDs == ["helper/echo", "invalid"])
    }
}
