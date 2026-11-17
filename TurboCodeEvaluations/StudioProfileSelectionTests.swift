import Foundation
import Testing
@testable import TurboCode

/// A profile override's Studio selection: it can only narrow Studio's VM tool
/// surface, older profiles keep the full default, and the skill selection
/// picks among user and bundled Studio skills.
@Suite("Studio profile selection")
struct StudioProfileSelectionTests {
    private static let context = ToolAccessContext(
        hasWorkspace: true,
        hasSkills: true,
        safariMCPEnabled: true,
        xcodeMCPEnabled: true,
        hasDelegateModel: true,
        repositoryMapDetail: .enhanced
    )

    @Test("A profile saved before the Studio fields keeps every Studio tool")
    func legacyProfileKeepsFullStudioSurface() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","baseModelID":"deepseek",
         "toolIDs":["read_file"],"skillIDs":[]}
        """
        let profile = try JSONDecoder().decode(UserDynamicProfile.self, from: Data(json.utf8))
        #expect(profile.studioToolIDs == nil)
        #expect(profile.studioSkillIDs == nil)
        #expect(profile.resolvedStudioToolIDs == nil)

        let full = ModelToolCatalog.coworkPlan(tier: .standard, context: Self.context)
        let selected = ModelToolCatalog.coworkPlan(
            tier: .standard,
            context: Self.context,
            selectedIDs: profile.resolvedStudioToolIDs
        )
        #expect(selected.registeredIDs == full.registeredIDs)
    }

    @Test("Required Studio tools stay on and host tools never enter a Studio plan")
    func selectionCannotDropRequiredOrAddHostTools() {
        var profile = UserDynamicProfile(name: "Lean", baseModelID: .deepseek)
        profile.studioToolIDs = ["vm_exec", "bash", "git", "edit_file"]

        #expect(profile.resolvedStudioToolIDs == [.vmExec])
        let full = ModelToolCatalog.coworkPlan(tier: .enhanced, context: Self.context)
        let plan = ModelToolCatalog.coworkPlan(
            tier: .enhanced,
            context: Self.context,
            selectedIDs: profile.resolvedStudioToolIDs
        )
        // Only the optional guide is dropped; the required VM tools stay.
        #expect(plan.registeredIDs == full.registeredIDs.subtracting([.turboCodeGuide]))
        #expect(plan.registeredIDs.isSuperset(of: [.vmExec, .vmFile, .vmExport, .vmViewImage]))
        #expect(!plan.registeredIDs.contains(.bash))
        #expect(!plan.registeredIDs.contains(.git))
    }

    @Test("Turning off a required Studio tool is ignored")
    func requiredToolsAreLocked() {
        var profile = UserDynamicProfile(name: "Lean", baseModelID: .llama)
        profile.setStudioTool(.vmViewImage, included: false)
        #expect(profile.containsStudioTool(.vmViewImage))
        #expect(profile.studioToolIDs == nil)

        profile.setStudioTool(.git, included: true)
        #expect(!profile.containsStudioTool(.git))
    }

    @Test("The guide is optional in Studio and its first removal keeps the rest")
    func guideCanBeTurnedOff() {
        var profile = UserDynamicProfile(name: "Lean", baseModelID: .llama)
        #expect(profile.containsStudioTool(.turboCodeGuide))

        profile.setStudioTool(.turboCodeGuide, included: false)
        #expect(!profile.containsStudioTool(.turboCodeGuide))
        #expect(profile.containsStudioTool(.vmExec))
        #expect(profile.studioToolIDs?.contains("turbocode_guide") == false)
    }

    @Test("A Studio skill selection picks by name among user and bundled skills")
    @MainActor
    func studioSkillSelectionFiltersCatalog() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = try Self.skill("user-notes", in: root)
        let bundledWeb = try Self.skill("studio-web-design", in: root, description: "Bundled web")
        let bundledDocs = try Self.skill("studio-documents", in: root)
        let override = try Self.skill("studio-documents", in: root, description: "Mine")

        var profile = UserDynamicProfile(name: "P", baseModelID: .deepseek, skillIDs: ["user-notes"])
        let defaults = DynamicProfileRuntimeSelection.studioSkills(
            from: [user],
            bundled: [bundledWeb, bundledDocs],
            profile: profile
        )
        #expect(defaults.map(\.name) == ["user-notes", "studio-web-design", "studio-documents"])

        // An empty selection drops the user's own skill but never the locked
        // bundled ones; the user's same-name skill still overrides the bundle.
        profile.studioSkillIDs = []
        let selected = DynamicProfileRuntimeSelection.studioSkills(
            from: [user, override],
            bundled: [bundledWeb, bundledDocs],
            profile: profile
        )
        #expect(selected.map(\.name) == ["studio-documents", "studio-web-design"])
        #expect(selected.first?.description == "Mine")
    }

    @Test("The context estimate prefers measured tool sizes and flags fallbacks")
    func contextEstimateUsesMeasurements() {
        let exec = ModelToolCatalog.descriptor(for: .vmExec)
        let file = ModelToolCatalog.descriptor(for: .vmFile)
        let measured = CapabilityContextEstimate(
            tools: [exec],
            skills: [],
            measuredToolTokens: [exec.id.runtimeName: 300],
            contextSize: 4_000
        )
        #expect(measured.toolTokens == 300)
        #expect(!measured.isApproximate)
        #expect(measured.fraction == 0.075)

        let mixed = CapabilityContextEstimate(
            tools: [exec, file],
            skills: [],
            measuredToolTokens: [exec.id.runtimeName: 300],
            contextSize: nil
        )
        #expect(mixed.isApproximate)
        #expect(mixed.toolTokens > 300 + CapabilityContextEstimate.unmeasuredSchemaTokens)
        #expect(mixed.fraction == nil)
    }

    @MainActor
    private static func skill(
        _ name: String,
        in root: URL,
        description: String = "Guidance"
    ) throws -> TurboCodeSkillDefinition {
        let url = root.appendingPathComponent("\(UUID().uuidString).md")
        try Data("---\nname: \(name)\ndescription: \(description)\n---\nFollow it.\n".utf8).write(to: url)
        return try TurboCodeSkillDefinition(contentsOf: url)
    }
}
