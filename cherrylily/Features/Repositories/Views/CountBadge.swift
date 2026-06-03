import SwiftUI

/// A small pill showing a count, used for the worktree count on a repo header
/// and the open-tab count on a worktree row. Numbers only, system colors,
/// adapts its contrast when its row is selected.
struct CountBadge: View {
  let count: Int
  var font: Font = .caption
  var isSelected: Bool = false

  var body: some View {
    Text("\(count)")
      .font(font)
      .fontWeight(.semibold)
      .monospacedDigit()
      .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(
        Capsule(style: .continuous)
          .fill(isSelected ? AnyShapeStyle(.white.opacity(0.25)) : AnyShapeStyle(.quaternary))
      )
      .accessibilityLabel("\(count)")
  }
}
