import AppKit
import SwiftUI

struct WorktreeRow: View {
  let name: String
  let info: WorktreeInfoEntry?
  let isHovered: Bool
  let isPinned: Bool
  let isMainWorktree: Bool
  let isLoading: Bool
  let taskStatus: WorktreeTaskStatus?
  let isRunScriptRunning: Bool
  let showsNotificationIndicator: Bool
  let notifications: [WorktreeTerminalNotification]
  let onFocusNotification: (WorktreeTerminalNotification) -> Void
  let summaryText: AttributedString
  let shortcutHint: String?
  let pinAction: (() -> Void)?
  let isSelected: Bool
  let archiveAction: (() -> Void)?
  @Environment(\.colorScheme) private var colorScheme

  // Hoisted out of `body` to avoid an AppKit font lookup / shortcut-string build on every render.
  private static let bodyFontAscender = NSFont.preferredFont(forTextStyle: .body).ascender
  private static let archiveShortcut = KeyboardShortcut(.delete, modifiers: .command).display

  var body: some View {
    let showsSpinner = (isLoading || taskStatus == .running) && !showsNotificationIndicator
    let branchIconName = isMainWorktree ? "star.fill" : (isPinned ? "pin.fill" : "arrow.triangle.branch")
    let displayAddedLines = info?.addedLines
    let displayRemovedLines = info?.removedLines
    let hasChangeCounts = displayAddedLines != nil && displayRemovedLines != nil
    let nameColor = colorScheme == .dark ? Color.white : Color.primary
    let bodyFontAscender = Self.bodyFontAscender
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        ZStack {
          if showsNotificationIndicator {
            NotificationPopoverButton(
              notifications: notifications,
              onFocusNotification: onFocusNotification
            ) {
              Image(systemName: "bell.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel("Unread notifications")
            }
            .opacity(showsSpinner ? 0 : 1)
          } else {
            Image(systemName: branchIconName)
              .font(.caption)
              .foregroundStyle(.secondary)
              .opacity(showsSpinner ? 0 : 1)
              .accessibilityHidden(true)
          }
          if showsSpinner {
            ProgressView()
              .controlSize(.small)
          }
        }
        .frame(width: 16, height: 16)
        .alignmentGuide(.firstTextBaseline) { _ in
          bodyFontAscender
        }
        Text(name)
          .font(.body)
          .foregroundStyle(nameColor)
          .lineLimit(1)
        Spacer(minLength: 4)
        if isRunScriptRunning {
          Image(systemName: "play.fill")
            .font(.caption)
            .foregroundStyle(.green)
            .help("Run script active")
            .accessibilityLabel("Run script active")
        }
        if hasChangeCounts, let displayAddedLines, let displayRemovedLines {
          WorktreeRowChangeCountView(
            addedLines: displayAddedLines,
            removedLines: displayRemovedLines,
            isSelected: isSelected
          )
        }
        if isHovered {
          Button {
            pinAction?()
          } label: {
            Image(systemName: isPinned ? "pin.slash" : "pin")
              .contentTransition(.symbolEffect(.replace))
              .accessibilityLabel(isPinned ? "Unpin worktree" : "Pin worktree")
          }
          .buttonStyle(.plain)
          .help(isPinned ? "Unpin" : "Pin to top")
          .disabled(pinAction == nil)
          Button {
            archiveAction?()
          } label: {
            Image(systemName: "archivebox")
              .accessibilityLabel("Archive worktree")
          }
          .buttonStyle(.plain)
          .help("Archive Worktree (\(Self.archiveShortcut))")
          .disabled(archiveAction == nil)
        }
      }
      WorktreeRowInfoView(
        summaryText: summaryText,
        shortcutHint: shortcutHint
      )
      .padding(.leading, 22)
    }
    .padding(.horizontal, 2)
    .frame(maxWidth: .infinity, minHeight: worktreeRowHeight, alignment: .center)
  }

  static func pullRequestMergeReadiness(
    for pullRequest: GithubPullRequest?
  ) -> PullRequestMergeReadiness? {
    guard let pullRequest, pullRequest.state.uppercased() == "OPEN" else {
      return nil
    }
    return PullRequestMergeReadiness(pullRequest: pullRequest)
  }

  /// Builds the row's summary line. Hoisted out of the view body so it can be precomputed
  /// once where row data is assembled rather than re-allocated on every `WorktreeRow` render
  /// (which re-runs on hover / colorScheme changes).
  static func summaryAttributedString(
    worktreeName: String,
    showsPullRequestTag: Bool,
    pullRequestNumber: Int?,
    pullRequestState: String?,
    mergeReadiness: PullRequestMergeReadiness?
  ) -> AttributedString {
    var result = AttributedString()
    func appendSeparator() {
      if !result.characters.isEmpty {
        var sep = AttributedString(" \u{2022} ")
        sep.foregroundColor = .secondary
        result.append(sep)
      }
    }
    if !worktreeName.isEmpty {
      var segment = AttributedString(worktreeName)
      segment.foregroundColor = .secondary
      result.append(segment)
    }
    if showsPullRequestTag, let pullRequestNumber {
      appendSeparator()
      var segment = AttributedString("PR #\(pullRequestNumber)")
      segment.foregroundColor = .secondary
      result.append(segment)
    }
    if pullRequestState == "MERGED" {
      appendSeparator()
      var segment = AttributedString("Merged")
      segment.foregroundColor = PullRequestBadgeStyle.mergedColor
      result.append(segment)
    } else if let mergeReadiness {
      appendSeparator()
      var segment = AttributedString(mergeReadiness.label)
      segment.foregroundColor = mergeReadiness.isBlocking ? .red : .green
      result.append(segment)
    }
    return result
  }

  private var worktreeRowHeight: CGFloat {
    42
  }
}

private struct WorktreeRowInfoView: View {
  let summaryText: AttributedString
  let shortcutHint: String?

  var body: some View {
    HStack(spacing: 4) {
      Text(summaryText)
        .lineLimit(1)
        .truncationMode(.tail)
        .layoutPriority(1)
      Spacer(minLength: 0)
      CommandKeyShortcutHint(text: shortcutHint)
    }
    .font(.caption)
    .frame(minHeight: 14)
  }
}

private struct WorktreeRowChangeCountView: View {
  let addedLines: Int
  let removedLines: Int
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 4) {
      Text("+\(addedLines)")
        .foregroundStyle(.green)
      Text("-\(removedLines)")
        .foregroundStyle(.red)
    }
    .font(.caption)
    .lineLimit(1)
    .padding(.horizontal, 4)
    .padding(.vertical, 0)
    .overlay {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .stroke(isSelected ? AnyShapeStyle(.secondary.opacity(0.3)) : AnyShapeStyle(.tertiary), lineWidth: 1)
    }
    .monospacedDigit()
  }
}
