import SwiftUI

struct RepoHeaderRow: View {
  let name: String
  let worktreeCount: Int
  let isRemoving: Bool
  var body: some View {
    HStack(spacing: 6) {
      Capsule(style: .continuous)
        .fill(.tint)
        .frame(width: 3, height: 18)
        .accessibilityHidden(true)
      Text(name)
        .font(.headline)
        .foregroundStyle(.primary)
        .lineLimit(1)
      if isRemoving {
        Text("Removing...")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 4)
      CountBadge(count: worktreeCount)
        .help("\(worktreeCount) worktree\(worktreeCount == 1 ? "" : "s")")
    }
  }
}
