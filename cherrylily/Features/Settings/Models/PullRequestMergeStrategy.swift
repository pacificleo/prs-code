import Foundation

nonisolated enum PullRequestMergeStrategy: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
  case merge
  case squash
  case rebase

  var id: String { rawValue }

  var title: String {
    switch self {
    case .merge:
      return "Merge"
    case .squash:
      return "Squash"
    case .rebase:
      return "Rebase"
    }
  }

  var ghArgument: String {
    rawValue
  }
}
