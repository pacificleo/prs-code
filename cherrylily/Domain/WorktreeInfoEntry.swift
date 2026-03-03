import Foundation

struct WorktreeInfoEntry: Equatable, Hashable {
  var addedLines: Int?
  var removedLines: Int?
  var pullRequest: GithubPullRequest?

  var isEmpty: Bool {
    addedLines == nil && removedLines == nil && pullRequest == nil
  }
}
