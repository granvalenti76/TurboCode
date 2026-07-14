import Foundation

// MARK: - TurboCode Configuration

/// Manages the `~/.turbocode/` directory and configuration files.
/// Created on first launch with sensible defaults.
public final class TurboCodeConfig {
    public static let shared = TurboCodeConfig()

    private var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".turbocode")
    }

    private var modelsURL: URL { rootURL.appendingPathComponent("models.json") }
    private var sessionsDir: URL { rootURL.appendingPathComponent("sessions") }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    // MARK: - First Launch

    public var isOnboarded: Bool {
        FileManager.default.fileExists(atPath: rootURL.path)
    }

    public func performOnboarding() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let defaultModels: [RemoteModelConfig] = [
            RemoteModelConfig(id: "llama", name: "Llama-server",
                url: "http://127.0.0.1:8080/v1",
                modelName: "/Users/granvalenti/.modelli/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf",
                temperature: 0.6),
            RemoteModelConfig(id: "apple-pcc", name: "Apple PCC",
                url: "http://127.0.0.1:1976/v1",
                modelName: "pcc", temperature: 0.6),
        ]
        try encoder.encode(defaultModels).write(to: modelsURL, options: .atomic)
    }

    // MARK: - Remote Models

    public func loadRemoteModels() throws -> [RemoteModelConfig] {
        guard FileManager.default.fileExists(atPath: modelsURL.path) else { return [] }
        return try JSONDecoder().decode([RemoteModelConfig].self, from: Data(contentsOf: modelsURL))
    }

    // MARK: - Per-Session Persistence

    /// Saves one session to `~/.turbocode/sessions/<id>.json`.
    /// Creates the sessions directory if needed.
    public func saveSession(_ session: StoredSession) throws {
        let dir = sessionsDir
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = sessionURL(for: session.id)
        try encoder.encode(session).write(to: url, options: .atomic)
        print("[TurboCode] Saved session \(session.id) → \(url.path)")
    }

    /// Loads one session by id.
    public func loadSession(id: String) throws -> StoredSession? {
        let url = sessionURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(StoredSession.self, from: Data(contentsOf: url))
    }

    /// Lists all session files, optionally filtered by project name.
    public func listSessions(project: String? = nil) throws -> [StoredSession] {
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
            return []
        }
        let files = try FileManager.default.contentsOfDirectory(at: sessionsDir,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        let all: [StoredSession] = try files.compactMap { url in
            try JSONDecoder().decode(StoredSession.self, from: Data(contentsOf: url))
        }
        if let project {
            return all.filter { $0.projectName == project }
        }
        return all
    }

    /// Deletes a session file.
    public func deleteSession(id: String) throws {
        let url = sessionURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func sessionURL(for id: String) -> URL {
        sessionsDir.appendingPathComponent("\(id).json")
    }
}

// MARK: - Remote Model Configuration

public struct RemoteModelConfig: Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var url: String
    public var modelName: String
    public var temperature: Double

    public init(id: String, name: String, url: String, modelName: String, temperature: Double) {
        self.id = id; self.name = name; self.url = url
        self.modelName = modelName; self.temperature = temperature
    }
}

// MARK: - Stored Session

/// A full persisted session: metadata + conversation blocks.
public struct StoredSession: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var projectName: String
    public var workspacePath: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var modelBackend: String
    public var blocks: [StoredBlock]

    public init(id: String = UUID().uuidString, title: String,
                projectName: String, workspacePath: String? = nil,
                createdAt: Date = .now, updatedAt: Date = .now,
                modelBackend: String = "Llama-server",
                blocks: [StoredBlock] = []) {
        self.id = id; self.title = title; self.projectName = projectName
        self.workspacePath = workspacePath; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.modelBackend = modelBackend
        self.blocks = blocks
    }
}

// MARK: - Stored Block

/// Codable snapshot of a ChatBlock.
public struct StoredBlock: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: String     // ChatBlockKind rawValue
    public let text: String
    public let createdAt: Date
    public var model: String?
    public var providerId: String?
    public var diffPatch: DiffPatchBlock?

    public init(id: String = UUID().uuidString, kind: String, text: String,
                createdAt: Date = .now, model: String? = nil, providerId: String? = nil,
                diffPatch: DiffPatchBlock? = nil) {
        self.id = id; self.kind = kind; self.text = text
        self.createdAt = createdAt; self.model = model; self.providerId = providerId
        self.diffPatch = diffPatch
    }
}
