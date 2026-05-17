import Foundation

struct Worktree: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let detail: String
  let workingDirectory: URL
  let repositoryRootURL: URL
  let createdAt: Date?

  nonisolated init(
    id: String,
    name: String,
    detail: String,
    workingDirectory: URL,
    repositoryRootURL: URL,
    createdAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.detail = detail
    self.workingDirectory = workingDirectory
    self.repositoryRootURL = repositoryRootURL
    self.createdAt = createdAt
  }
}

extension Worktree {
  /// Environment variables exposed to all Supacode scripts.
  var scriptEnvironment: [String: String] {
    [
      "CHERRYLILY_WORKTREE_PATH": workingDirectory.path(percentEncoded: false),
      "CHERRYLILY_ROOT_PATH": repositoryRootURL.path(percentEncoded: false),
    ]
  }

  /// Shell export statements for prepending to scripts.
  ///
  /// All exports joined into a single line with `;` so only one history entry
  /// is created per setup (instead of one per env var). Leading space lets
  /// users with `HIST_IGNORE_SPACE` (zsh `setopt`) skip the line entirely.
  var scriptEnvironmentExportPrefix: String {
    let exports = scriptEnvironment
      .sorted(by: { $0.key < $1.key })
      .map { "export \($0.key)='\($0.value.replacing("'", with: "'\"'\"'"))'" }
      .joined(separator: "; ")
    return " \(exports)\n"
  }
}
