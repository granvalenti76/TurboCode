import Foundation
import Testing
@testable import TurboCode

@Suite("AnchorSignal model assets")
struct AnchorSignalAssetTests {
    @Test("Dynamic routing remains unavailable until the model is prepared")
    @MainActor
    func preparedAssetsGateTheFeature() {
        let suiteName = "AnchorSignalAssetTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: "dynamicRoutingFeatureEnabled")
        preferences.set(true, forKey: "dynamicRoutingEnabled")

        let unavailable = ModelRuntimeStore(
            preferences: preferences,
            dynamicRoutingAssetsPrepared: false
        )
        #expect(!unavailable.dynamicRoutingFeatureEnabled)
        #expect(!unavailable.dynamicRoutingEnabled)
        #expect(!unavailable.dynamicRoutingSupported)

        let prepared = ModelRuntimeStore(
            preferences: preferences,
            dynamicRoutingAssetsPrepared: true
        )
        #expect(prepared.dynamicRoutingFeatureEnabled)
        #expect(prepared.dynamicRoutingEnabled)
    }

    @Test("Installed model files require the pinned size and digest")
    func installedAssetValidationRejectsDamage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnchorSignalAssets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("model.bin")
        try Data("verified model".utf8).write(to: fileURL)
        let descriptor = AnchorSignalAssetDescriptor(
            version: "test",
            archiveURL: URL(string: "https://example.invalid/model.zip")!,
            archiveSizeBytes: 0,
            archiveSHA256: "",
            installedDirectoryName: "fixture",
            files: [
                AnchorSignalAssetFile(
                    path: "model.bin",
                    sizeBytes: 14,
                    sha256: try AnchorSignalAssetDescriptor.sha256(at: fileURL)
                )
            ]
        )

        try descriptor.validateInstalledFiles(at: root)
        try Data("damaged model!".utf8).write(to: fileURL)
        #expect(throws: AnchorSignalAssetError.self) {
            try descriptor.validateInstalledFiles(at: root)
        }
    }
}
