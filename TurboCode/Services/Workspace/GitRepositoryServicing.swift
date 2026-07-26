import Foundation

/// Read and mutation boundary used by workspace-facing state.
nonisolated protocol GitRepositoryServicing: Sendable {
    func isGitRepository(at directory: URL) async -> Bool
    func currentBranch(at directory: URL) async -> String?
    func allBranches(at directory: URL) async -> [String]
    func undoCommit(expectedHash: String, at directory: URL) async -> String?
    func checkout(branch: String, at directory: URL) async -> Bool
    func fetchChangedFiles(at url: URL) async throws -> [GitFileStatus]
    func fetchDiff(for filePath: String, at url: URL) async throws -> [DiffLine]
}
