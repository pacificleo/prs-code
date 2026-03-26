import ComposableArchitecture
import Sharing
import SwiftUI

struct SidebarFooterView: View {
  let store: StoreOf<RepositoriesFeature>
  @Environment(\.surfaceBottomChromeBackgroundOpacity) private var surfaceBottomChromeBackgroundOpacity
  @Environment(\.openURL) private var openURL
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let overrides = settingsFile.global.shortcutOverrides
    let openRepo = AppShortcuts.openRepository.effective(from: overrides)
    let refresh = AppShortcuts.refreshWorktrees.effective(from: overrides)
    let archived = AppShortcuts.archivedWorktrees.effective(from: overrides)
    let settings = AppShortcuts.openSettings.effective(from: overrides)
    HStack {
      Button {
        store.send(.setOpenPanelPresented(true))
      } label: {
        HStack(spacing: 6) {
          Label("Add Repository", systemImage: "folder.badge.plus")
            .font(.callout)
          if commandKeyObserver.isPressed {
            ShortcutHintView(text: openRepo?.display ?? "", color: .secondary)
          }
        }
      }
      .help("Add Repository (\(openRepo?.display ?? "none"))")
      Spacer()
      Button {
        store.send(.toggleWorktreeSortOrder)
      } label: {
        Image(systemName: store.sortWorktreesAlphabetically ? "textformat.abc" : "arrow.up.arrow.down")
          .accessibilityLabel(
            store.sortWorktreesAlphabetically ? "Sort by manual order" : "Sort alphabetically"
          )
      }
      .help(store.sortWorktreesAlphabetically ? "Sort by manual order" : "Sort alphabetically")
      Menu {
        Button("Submit GitHub issue", systemImage: "exclamationmark.bubble") {
          if let url = URL(string: "https://github.com/pacificleo/prs-code/issues/new") {
            openURL(url)
          }
        }
        .help("Submit GitHub issue")
      } label: {
        Label("Help", systemImage: "questionmark.circle")
          .labelStyle(.iconOnly)
      }
      .menuIndicator(.hidden)
      .help("Help")
      Button {
        store.send(.refreshWorktrees)
      } label: {
        Image(systemName: "arrow.clockwise")
          .symbolEffect(.rotate, options: .repeating, isActive: store.state.isRefreshingWorktrees)
          .accessibilityLabel("Refresh Worktrees")
      }
      .help("Refresh Worktrees (\(refresh?.display ?? "none"))")
      .disabled(store.state.repositoryRoots.isEmpty && !store.state.isRefreshingWorktrees)
      Button {
        store.send(.selectArchivedWorktrees)
      } label: {
        Image(systemName: "archivebox")
          .accessibilityLabel("Archived Worktrees")
      }
      .help("Archived Worktrees (\(archived?.display ?? "none"))")
      Button("Settings", systemImage: "gearshape") {
        SettingsWindowManager.shared.show()
      }
      .labelStyle(.iconOnly)
      .help("Settings (\(settings?.display ?? "none"))")
    }
    .buttonStyle(.plain)
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .windowBackgroundColor).opacity(surfaceBottomChromeBackgroundOpacity))
    .overlay(alignment: .top) {
      Divider()
    }
  }
}
