import CoreAI
import CryptoKit
import Foundation
import Observation

nonisolated enum AnchorSignalAssetState: Equatable, Sendable {
    case notInstalled
    case downloading
    case verifying
    case needsPreparation
    case preparing
    case ready
    case failed(String)

    var isWorking: Bool {
        switch self {
        case .downloading, .verifying, .preparing:
            true
        default:
            false
        }
    }

    var title: String {
        switch self {
        case .notInstalled: "Not installed"
        case .downloading: "Downloading…"
        case .verifying: "Verifying…"
        case .needsPreparation: "Needs preparation"
        case .preparing: "Preparing for this Mac…"
        case .ready: "Ready"
        case .failed: "Installation failed"
        }
    }
}

nonisolated struct AnchorSignalAssetFile: Sendable {
    let path: String
    let sizeBytes: Int64
    let sha256: String
}

/// Pins the remotely hosted model to one reviewed release. The archive digest
/// protects the download, while per-file digests also catch incomplete or
/// damaged extraction before CoreAI sees the model.
nonisolated struct AnchorSignalAssetDescriptor: Sendable {
    static let current = Self(
        version: "1.0.0",
        archiveURL: URL(string: "https://github.com/granvalenti76/Turbocode-Models/releases/download/anchorsignal-coreai-v1.0.0/anchorsignal-small-coreai-v1.0.0.zip")!,
        archiveSizeBytes: 276_494_808,
        archiveSHA256: "061f69a7db94d586002befbd77c0aa37f7671a4b75a233d4013a6cc5938c9983",
        installedDirectoryName: "anchorsignal-small",
        files: [
            .init(path: "TextEncoder.aimodel/main.hash", sizeBytes: 32, sha256: "f4d88d4c17632950d2fdbbfaafaeffbd24efd46128b34877fd8d9a9d5ff30fcc"),
            .init(path: "TextEncoder.aimodel/main.mlirb", sizeBytes: 470_141_838, sha256: "a8ddc5498ba96d569eb795fd8791a04e807ab9d09a01f2f20f4028e47469d457"),
            .init(path: "TextEncoder.aimodel/metadata.json", sizeBytes: 105, sha256: "00ade15e4cc3db9a1b5e47129a61b6cd96dff5057b5d5b8b92ef09ac8d6441c4"),
            .init(path: "manifest.json", sizeBytes: 240, sha256: "06acea5b6974d76756f6c0ef8bfc96c47e3fefc17c273eade2c8bec6bf355434"),
            .init(path: "tokenizer/special_tokens_map.json", sizeBytes: 965, sha256: "38d989b0fdad0fec0c67c14b1f3c8b68184022cf6d4adc5444526ced8653f738"),
            .init(path: "tokenizer/tokenizer.json", sizeBytes: 17_082_800, sha256: "cd98e5698b201ba914efb8c18b6709fa8735ab71dcad8d2b431e52e8bf68d932"),
            .init(path: "tokenizer/tokenizer_config.json", sizeBytes: 1_203, sha256: "dbdcd9767f0481fd8fd8cd6bce3e73dae7f5c44ce22ae1fde00a66498e71b454")
        ]
    )

    let version: String
    let archiveURL: URL
    let archiveSizeBytes: Int64
    let archiveSHA256: String
    let installedDirectoryName: String
    let files: [AnchorSignalAssetFile]

    func versionDirectory(in homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent(".turbocode/models/anchorsignal", isDirectory: true)
            .appendingPathComponent("v\(version)", isDirectory: true)
    }

    func installedRoot(in homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        versionDirectory(in: homeDirectory)
            .appendingPathComponent(installedDirectoryName, isDirectory: true)
    }

    func modelURL(in homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        installedRoot(in: homeDirectory)
            .appendingPathComponent("TextEncoder.aimodel", isDirectory: true)
    }

    func tokenizerURL(in homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        installedRoot(in: homeDirectory)
            .appendingPathComponent("tokenizer/tokenizer.json")
    }

    func hasInstalledFiles(in homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let root = installedRoot(in: homeDirectory)
        return files.allSatisfy {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0.path).path)
        }
    }

    func isPrepared(in homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard hasInstalledFiles(in: homeDirectory) else { return false }
        do {
            return try AIModelCache.default.model(
                for: modelURL(in: homeDirectory),
                options: .default
            ) != nil
        } catch {
            return false
        }
    }

    func validateArchive(at archiveURL: URL) throws {
        let values = try archiveURL.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == archiveSizeBytes else {
            throw AnchorSignalAssetError.archiveSizeMismatch
        }
        guard try Self.sha256(at: archiveURL) == archiveSHA256 else {
            throw AnchorSignalAssetError.archiveDigestMismatch
        }
    }

    func validateInstalledFiles(at root: URL) throws {
        for file in files {
            let url = root.appendingPathComponent(file.path)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true,
                  Int64(values.fileSize ?? -1) == file.sizeBytes else {
                throw AnchorSignalAssetError.installedFileMismatch(file.path)
            }
            guard try Self.sha256(at: url) == file.sha256 else {
                throw AnchorSignalAssetError.installedFileMismatch(file.path)
            }
        }
    }

    static func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
@Observable
final class AnchorSignalAssetManager {
    private(set) var state: AnchorSignalAssetState = .notInstalled

    let descriptor: AnchorSignalAssetDescriptor
    private let homeDirectory: URL

    init(
        descriptor: AnchorSignalAssetDescriptor = .current,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.descriptor = descriptor
        self.homeDirectory = homeDirectory
        refreshStatus()
    }

    var isReady: Bool { state == .ready }

    func refreshStatus() {
        if descriptor.isPrepared(in: homeDirectory) {
            state = .ready
        } else if descriptor.hasInstalledFiles(in: homeDirectory) {
            state = .needsPreparation
        } else {
            state = .notInstalled
        }
    }

    /// Installs to a stable final URL before specialization because CoreAI
    /// indexes its cache by source URL and specialization options.
    func installAndPrepare() async -> Bool {
        guard !state.isWorking else { return false }
        do {
            if !descriptor.hasInstalledFiles(in: homeDirectory) {
                state = .downloading
                let (temporaryArchive, response) = try await URLSession.shared.download(
                    from: descriptor.archiveURL
                )
                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200 else {
                    throw AnchorSignalAssetError.downloadFailed
                }

                state = .verifying
                let descriptor = descriptor
                let homeDirectory = homeDirectory
                try await Task.detached(priority: .userInitiated) {
                    try descriptor.installArchive(
                        at: temporaryArchive,
                        in: homeDirectory
                    )
                }.value
            }

            state = .preparing
            _ = try await AIModel.specialize(
                contentsOf: descriptor.modelURL(in: homeDirectory),
                options: .default,
                cache: .default,
                cachePolicy: .default
            )
            let classifier = AnchorSignalClassifier(
                configuration: .init(
                    modelURL: descriptor.modelURL(in: homeDirectory),
                    tokenizerURL: descriptor.tokenizerURL(in: homeDirectory),
                    maximumTokenCount: 512
                )
            )
            try await classifier.validateInstalledAssets()
            state = .ready
            return true
        } catch is CancellationError {
            refreshStatus()
            return false
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }
}

private extension AnchorSignalAssetDescriptor {
    nonisolated func installArchive(at archiveURL: URL, in homeDirectory: URL) throws {
        try validateArchive(at: archiveURL)

        let fileManager = FileManager.default
        let parent = versionDirectory(in: homeDirectory).deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".v\(version)-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let backup = parent.appendingPathComponent(
            ".v\(version)-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: backup)
        }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        // `ditto` is the platform ZIP extractor. The fixed executable and
        // pinned archive digest avoid exposing general shell execution here.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, staging.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AnchorSignalAssetError.extractionFailed
        }

        try validateInstalledFiles(
            at: staging.appendingPathComponent(installedDirectoryName, isDirectory: true)
        )

        let destination = versionDirectory(in: homeDirectory)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: backup)
            do {
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                try? fileManager.moveItem(at: backup, to: destination)
                throw error
            }
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }
}

nonisolated enum AnchorSignalAssetError: LocalizedError {
    case downloadFailed
    case archiveSizeMismatch
    case archiveDigestMismatch
    case extractionFailed
    case installedFileMismatch(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            "The AnchorSignal model could not be downloaded."
        case .archiveSizeMismatch:
            "The AnchorSignal download has an unexpected size."
        case .archiveDigestMismatch:
            "The AnchorSignal download failed its integrity check."
        case .extractionFailed:
            "The AnchorSignal model could not be extracted."
        case .installedFileMismatch(let path):
            "The installed AnchorSignal file is invalid: \(path)"
        }
    }
}
