import Foundation

// MARK: - TurboCode Configuration

/// Manages the `~/.turbocode/` directory and configuration files.
/// Created on first launch with sensible defaults.
public final class TurboCodeConfig: Sendable {
    public static let shared = TurboCodeConfig()

    /// Root directory: `~/.turbocode/`
    private var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".turbocode")
    }

    /// `~/.turbocode/models.json` — remote model configurations.
    private var modelsURL: URL {
        rootURL.appendingPathComponent("models.json")
    }

    /// `~/.turbocode/sessions.json` — persisted session metadata.
    private var sessionsURL: URL {
        rootURL.appendingPathComponent("sessions.json")
    }

    // MARK: - First Launch

    /// Returns `true` if the config directory exists (not first launch).
    public var isOnboarded: Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".turbocode").path
        return FileManager.default.fileExists(atPath: path)
    }

    /// Creates `~/.turbocode/` with default configuration files.
    public func performOnboarding() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let defaultModels: [RemoteModelConfig] = [
            RemoteModelConfig(
                id: "llama",
                name: "Llama-server",
                url: "http://127.0.0.1:8080/v1",
                modelName: "/Users/granvalenti/.modelli/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf",
                temperature: 0.6
            ),
            RemoteModelConfig(
                id: "apple-pcc",
                name: "Apple PCC",
                url: "http://127.0.0.1:1976/v1",
                modelName: "pcc",
                temperature: 0.6
            )
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let modelsData = try encoder.encode(defaultModels)
        try modelsData.write(to: modelsURL, options: .atomic)

        let emptySessions = try encoder.encode([ArchivedSession]())
        try emptySessions.write(to: sessionsURL, options: .atomic)
    }

    // MARK: - Remote Models

    /// Reads the current remote model configurations.
    public func loadRemoteModels() throws -> [RemoteModelConfig] {
        guard FileManager.default.fileExists(atPath: modelsURL.path) else {
            return []
        }
        let data = try Data(contentsOf: modelsURL)
        return try JSONDecoder().decode([RemoteModelConfig].self, from: data)
    }

    // MARK: - Session Persistence

    /// Persists session metadata to disk.
    public func saveSessions(_ sessions: [ArchivedSession]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(sessions)
        try data.write(to: sessionsURL, options: .atomic)
    }

    /// Loads persisted session metadata.
    public func loadSessions() throws -> [ArchivedSession] {
        guard FileManager.default.fileExists(atPath: sessionsURL.path) else {
            return []
        }
        let data = try Data(contentsOf: sessionsURL)
        return try JSONDecoder().decode([ArchivedSession].self, from: data)
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
        self.id = id
        self.name = name
        self.url = url
        self.modelName = modelName
        self.temperature = temperature
    }
}

// MARK: - Archived Session

/// Lightweight metadata for a persisted session, grouped under a project.
public struct ArchivedSession: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var projectName: String       // workspace last path component
    public var workspacePath: String?    // full path
    public var createdAt: Date
    public var updatedAt: Date
    public var modelBackend: String      // rawValue of ModelBackend

    public init(
        id: String = UUID().uuidString,
        title: String,
        projectName: String,
        workspacePath: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        modelBackend: String = "Llama-server"
    ) {
        self.id = id
        self.title = title
        self.projectName = projectName
        self.workspacePath = workspacePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modelBackend = modelBackend
    }
}
