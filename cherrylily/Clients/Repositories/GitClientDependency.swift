import ComposableArchitecture
import Foundation

struct GitClientDependency: Sendable {
  var repoRoot: @Sendable (URL) async throws -> URL
  var worktrees: @Sendable (URL) async throws -> [Worktree]
  var pruneWorktrees: @Sendable (URL) async throws -> Void
  var localBranchNames: @Sendable (URL) async throws -> Set<String>
  var isValidBranchName: @Sendable (String, URL) async -> Bool
  var branchRefs: @Sendable (URL) async throws -> [String]
  var defaultRemoteBranchRef: @Sendable (URL) async throws -> String?
  var automaticWorktreeBaseRef: @Sendable (URL) async -> String?
  var ignoredFileCount: @Sendable (URL) async throws -> Int
  var untrackedFileCount: @Sendable (URL) async throws -> Int
  var createWorktree:
    @Sendable (
      _ name: String,
      _ repoRoot: URL,
      _ baseDirectory: URL,
      _ copyIgnored: Bool,
      _ copyUntracked: Bool,
      _ baseRef: String
    ) async throws
      -> Worktree
  var createWorktreeStream:
    @Sendable (
      _ name: String,
      _ repoRoot: URL,
      _ baseDirectory: URL,
      _ copyIgnored: Bool,
      _ copyUntracked: Bool,
      _ baseRef: String
    ) -> AsyncThrowingStream<GitWorktreeCreateEvent, Error>
  var removeWorktree: @Sendable (_ worktree: Worktree, _ deleteBranch: Bool) async throws -> URL
  var isBareRepository: @Sendable (_ repoRoot: URL) async throws -> Bool
  var branchName: @Sendable (URL) async -> String?
  var lineChanges: @Sendable (URL) async -> (added: Int, removed: Int)?
  var headSHA: @Sendable (URL) async -> String?
  var renameBranch: @Sendable (_ worktreeURL: URL, _ branchName: String) async throws -> Void
  var remoteInfo: @Sendable (_ repositoryRoot: URL) async -> GithubRemoteInfo?
}

extension GitClientDependency: DependencyKey {
  static let liveValue: GitClientDependency = {
    // One shared GitClient instead of allocating a fresh one per call. The struct
    // is a thin Sendable wrapper around ShellClient; reusing it avoids per-poll
    // allocation on the steady-state worktree-info refresh path.
    let client = GitClient()
    return GitClientDependency(
      repoRoot: { try await client.repoRoot(for: $0) },
      worktrees: { try await client.worktrees(for: $0) },
      pruneWorktrees: { try await client.pruneWorktrees(for: $0) },
      localBranchNames: { try await client.localBranchNames(for: $0) },
      isValidBranchName: { branchName, repoRoot in
        await client.isValidBranchName(branchName, for: repoRoot)
      },
      branchRefs: { try await client.branchRefs(for: $0) },
      defaultRemoteBranchRef: { try await client.defaultRemoteBranchRef(for: $0) },
      automaticWorktreeBaseRef: { await client.automaticWorktreeBaseRef(for: $0) },
      ignoredFileCount: { try await client.ignoredFileCount(for: $0) },
      untrackedFileCount: { try await client.untrackedFileCount(for: $0) },
      createWorktree: { name, repoRoot, baseDirectory, copyIgnored, copyUntracked, baseRef in
        try await client.createWorktree(
          named: name,
          in: repoRoot,
          baseDirectory: baseDirectory,
          copyFiles: (ignored: copyIgnored, untracked: copyUntracked),
          baseRef: baseRef
        )
      },
      createWorktreeStream: { name, repoRoot, baseDirectory, copyIgnored, copyUntracked, baseRef in
        client.createWorktreeStream(
          named: name,
          in: repoRoot,
          baseDirectory: baseDirectory,
          copyFiles: (ignored: copyIgnored, untracked: copyUntracked),
          baseRef: baseRef
        )
      },
      removeWorktree: { worktree, deleteBranch in
        try await client.removeWorktree(worktree, deleteBranch: deleteBranch)
      },
      isBareRepository: { repoRoot in
        try await client.isBareRepository(for: repoRoot)
      },
      branchName: { client.branchName(for: $0) },
      lineChanges: { await client.lineChanges(at: $0) },
      headSHA: { await client.headSHA(for: $0) },
      renameBranch: { worktreeURL, branchName in
        try await client.renameBranch(in: worktreeURL, to: branchName)
      },
      remoteInfo: { repositoryRoot in
        await client.remoteInfo(for: repositoryRoot)
      }
    )
  }()
  static let testValue = liveValue
}

extension DependencyValues {
  var gitClient: GitClientDependency {
    get { self[GitClientDependency.self] }
    set { self[GitClientDependency.self] = newValue }
  }
}
