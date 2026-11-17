import Foundation

/// How much of the model's context a profile's tools and skills take before
/// the conversation starts, shown under a profile's Included Capabilities.
///
/// It is an estimate: four characters per token, the same rule as
/// `TranscriptContextProjection`. A tool's cost comes from its real
/// definition (name, description, argument schema) once a session has
/// registered it (see `ToolDefinitionSizeStore`); before that, from its
/// catalog summary plus a typical schema allowance, and the estimate says so.
nonisolated struct CapabilityContextEstimate: Equatable, Sendable {
    /// Allowance for a tool's argument schema when it was never measured.
    /// Roughly the median of the measured TurboCode tools; it only keeps the
    /// unmeasured case from looking free.
    static let unmeasuredSchemaTokens = 120

    let toolTokens: Int
    let skillTokens: Int
    /// The model's context window, when known.
    let contextSize: Int?
    /// True when at least one tool cost is a fallback, not a measurement.
    let isApproximate: Bool

    var totalTokens: Int { toolTokens + skillTokens }

    /// Share of the context window, clamped to 0...1; nil when the window is unknown.
    var fraction: Double? {
        guard let contextSize, contextSize > 0 else { return nil }
        return min(max(Double(totalTokens) / Double(contextSize), 0), 1)
    }

    init(
        tools: [ToolCapabilityDescriptor],
        skills: [TurboCodeSkillDefinition],
        measuredToolTokens: [String: Int],
        contextSize: Int?
    ) {
        var approximate = false
        toolTokens = tools.reduce(0) { sum, tool in
            if let measured = measuredToolTokens[tool.id.runtimeName] {
                return sum + measured
            }
            approximate = true
            return sum
                + Self.estimatedTokens(for: "\(tool.id.runtimeName) \(tool.summary)")
                + Self.unmeasuredSchemaTokens
        }
        // A skill costs its catalog line in the instructions plus its name in
        // the load_skill schema; its body is only read when it is loaded.
        skillTokens = skills.reduce(0) { sum, skill in
            sum + Self.estimatedTokens(for: "- \(skill.name): \(skill.description)")
                + Self.estimatedTokens(for: skill.name)
        }
        self.contextSize = contextSize
        isApproximate = approximate
    }

    static func estimatedTokens(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, (text.count + 3) / 4)
    }
}
