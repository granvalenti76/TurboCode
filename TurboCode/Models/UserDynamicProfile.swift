import Foundation

nonisolated enum ProfileBaseModelID: String, CaseIterable, Codable, Identifiable, Sendable, Hashable {
    case onDevice = "on-device"
    case llama
    case pcc = "apple-pcc"
    case deepseek

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice: "On-device"
        case .llama: "Llama"
        case .pcc: "Apple PCC"
        case .deepseek: "DeepSeek"
        }
    }

    var systemImage: String {
        switch self {
        case .onDevice: "apple.logo"
        case .llama: "desktopcomputer"
        case .pcc: "cloud"
        case .deepseek: "sparkles"
        }
    }

    var remoteModelID: String? {
        self == .onDevice ? nil : rawValue
    }
}

nonisolated struct UserDynamicProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var summary: String
    var baseModelID: ProfileBaseModelID
    var greedyMode: Bool
    var toolIDs: [String]
    var skillIDs: [String]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        baseModelID: ProfileBaseModelID,
        greedyMode: Bool = false,
        toolIDs: [String] = [],
        skillIDs: [String] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.baseModelID = baseModelID
        self.greedyMode = greedyMode
        self.toolIDs = toolIDs.uniqued()
        self.skillIDs = skillIDs.uniqued()
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, baseModelID, greedyMode, toolIDs, skillIDs
        case createdAt, updatedAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        baseModelID = try values.decode(ProfileBaseModelID.self, forKey: .baseModelID)
        greedyMode = try values.decodeIfPresent(Bool.self, forKey: .greedyMode) ?? false
        toolIDs = try values.decodeIfPresent([String].self, forKey: .toolIDs) ?? []
        skillIDs = try values.decodeIfPresent([String].self, forKey: .skillIDs) ?? []
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    var resolvedToolIDs: Set<ToolCapabilityID> {
        var result = Set(toolIDs.compactMap(ToolCapabilityID.init(rawValue:)))
        if !skillIDs.isEmpty {
            result.insert(.loadSkill)
        }
        return result
    }

    func validated() throws -> UserDynamicProfile {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty else { throw UserDynamicProfileError.missingName }
        guard value.name.count <= 64 else { throw UserDynamicProfileError.nameTooLong }
        value.toolIDs = toolIDs.uniqued()
        value.skillIDs = skillIDs.uniqued()
        return value
    }
}

nonisolated enum UserDynamicProfileError: LocalizedError {
    case missingName
    case nameTooLong
    case duplicateName(String)
    case profileNotFound

    var errorDescription: String? {
        switch self {
        case .missingName: "Enter a profile name."
        case .nameTooLong: "Profile names must be 64 characters or fewer."
        case .duplicateName(let name): "A profile named '\(name)' already exists."
        case .profileNotFound: "The selected profile no longer exists."
        }
    }
}

private nonisolated extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
