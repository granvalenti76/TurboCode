/// Patch mutation boundary used by timeline undo operations.
nonisolated protocol DiffPatchApplying: Sendable {
    func apply(
        patch: String,
        workspaceRoot: String,
        reverse: Bool,
        tolerateInaccurateEOF: Bool
    ) async throws
}
