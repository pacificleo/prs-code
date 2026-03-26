import AppKit
import ComposableArchitecture
import Sharing
import SwiftUI

struct WorktreeCommands: Commands {
  @Bindable var store: StoreOf<AppFeature>
  @FocusedValue(\.openSelectedWorktreeAction) private var openSelectedWorktreeAction
  @FocusedValue(\.confirmWorktreeAction) private var confirmWorktreeAction
  @FocusedValue(\.archiveWorktreeAction) private var archiveWorktreeAction
  @FocusedValue(\.deleteWorktreeAction) private var deleteWorktreeAction
  @FocusedValue(\.runScriptAction) private var runScriptAction
  @FocusedValue(\.stopRunScriptAction) private var stopRunScriptAction
  @FocusedValue(\.visibleHotkeyWorktreeRows) private var visibleHotkeyWorktreeRows

  init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  var body: some Commands {
    let overrides = store.settings.shortcutOverrides
    let repositories = store.repositories
    let orderedRows = visibleHotkeyWorktreeRows ?? repositories.orderedWorktreeRows()
    let pullRequestURL = selectedPullRequestURL
    let githubIntegrationEnabled = store.settings.githubIntegrationEnabled
    let selectNext = AppShortcuts.selectNextWorktree.effective(from: overrides)
    let selectPrevious = AppShortcuts.selectPreviousWorktree.effective(from: overrides)
    let archive = AppShortcuts.archiveWorktree.effective(from: overrides)
    let deleteWt = AppShortcuts.deleteWorktree.effective(from: overrides)
    let confirm = AppShortcuts.confirmWorktreeAction.effective(from: overrides)
    let openRepo = AppShortcuts.openRepository.effective(from: overrides)
    let openWorktree = AppShortcuts.openFinder.effective(from: overrides)
    let openPR = AppShortcuts.openPullRequest.effective(from: overrides)
    let newWt = AppShortcuts.newWorktree.effective(from: overrides)
    let archived = AppShortcuts.archivedWorktrees.effective(from: overrides)
    let refresh = AppShortcuts.refreshWorktrees.effective(from: overrides)
    let run = AppShortcuts.runScript.effective(from: overrides)
    let stop = AppShortcuts.stopRunScript.effective(from: overrides)
    CommandMenu("Worktrees") {
      Button("Select Next Worktree") {
        store.send(.repositories(.selectNextWorktree))
      }
      .appKeyboardShortcut(selectNext)
      .help("Select Next Worktree (\(selectNext?.display ?? "none"))")
      .disabled(orderedRows.isEmpty)
      Button("Select Previous Worktree") {
        store.send(.repositories(.selectPreviousWorktree))
      }
      .appKeyboardShortcut(selectPrevious)
      .help("Select Previous Worktree (\(selectPrevious?.display ?? "none"))")
      .disabled(orderedRows.isEmpty)
      Divider()
      let worktreeShortcutsList = worktreeShortcuts(from: overrides)
      ForEach(worktreeShortcutsList.indices, id: \.self) { index in
        WorktreeShortcutButton(
          index: index,
          shortcut: worktreeShortcutsList[index],
          orderedRows: orderedRows,
          store: store
        )
      }
    }
    CommandGroup(replacing: .newItem) {
      Button("Open Repository...", systemImage: "folder") {
        store.send(.repositories(.setOpenPanelPresented(true)))
      }
      .appKeyboardShortcut(openRepo)
      .help("Open Repository (\(openRepo?.display ?? "none"))")
      Button("Open Worktree") {
        openSelectedWorktreeAction?()
      }
      .appKeyboardShortcut(openWorktree)
      .help("Open Worktree (\(openWorktree?.display ?? "none"))")
      .disabled(openSelectedWorktreeAction == nil)
      Button("Open Pull Request on GitHub") {
        if let pullRequestURL {
          NSWorkspace.shared.open(pullRequestURL)
        }
      }
      .appKeyboardShortcut(openPR)
      .help("Open Pull Request on GitHub (\(openPR?.display ?? "none"))")
      .disabled(pullRequestURL == nil || !githubIntegrationEnabled)
      Button("New Worktree", systemImage: "plus") {
        store.send(.repositories(.createRandomWorktree))
      }
      .appKeyboardShortcut(newWt)
      .help("New Worktree (\(newWt?.display ?? "none"))")
      .disabled(!repositories.canCreateWorktree)
      Button("Archived Worktrees") {
        store.send(.repositories(.selectArchivedWorktrees))
      }
      .appKeyboardShortcut(archived)
      .help("Archived Worktrees (\(archived?.display ?? "none"))")
      Button("Archive Worktree") {
        archiveWorktreeAction?()
      }
      .appKeyboardShortcut(archive)
      .help("Archive Worktree (\(archive?.display ?? "none"))")
      .disabled(archiveWorktreeAction == nil)
      Button("Delete Worktree") {
        deleteWorktreeAction?()
      }
      .appKeyboardShortcut(deleteWt)
      .help("Delete Worktree (\(deleteWt?.display ?? "none"))")
      .disabled(deleteWorktreeAction == nil)
      Button("Confirm Worktree Action") {
        confirmWorktreeAction?()
      }
      .appKeyboardShortcut(confirm)
      .help("Confirm Worktree Action (\(confirm?.display ?? "none"))")
      .disabled(confirmWorktreeAction == nil)
      Button("Refresh Worktrees") {
        store.send(.repositories(.refreshWorktrees))
      }
      .appKeyboardShortcut(refresh)
      .help("Refresh Worktrees (\(refresh?.display ?? "none"))")
      Divider()
      Button("Run Script") {
        runScriptAction?()
      }
      .appKeyboardShortcut(run)
      .help("Run Script (\(run?.display ?? "none"))")
      .disabled(runScriptAction == nil)
      Button("Stop Script") {
        stopRunScriptAction?()
      }
      .appKeyboardShortcut(stop)
      .help("Stop Script (\(stop?.display ?? "none"))")
      .disabled(stopRunScriptAction == nil)
    }
  }

  private func worktreeShortcuts(from overrides: [AppShortcutID: AppShortcutOverride]) -> [AppShortcut?] {
    AppShortcuts.worktreeSelection.map { $0.effective(from: overrides) }
  }

  private var selectedPullRequestURL: URL? {
    let repositories = store.repositories
    guard let selectedWorktreeID = repositories.selectedWorktreeID else { return nil }
    let pullRequest = repositories.worktreeInfoByID[selectedWorktreeID]?.pullRequest
    return pullRequest.flatMap { URL(string: $0.url) }
  }

}

private struct WorktreeShortcutButton: View {
  let index: Int
  let shortcut: AppShortcut?
  let orderedRows: [WorktreeRowModel]
  let store: StoreOf<AppFeature>

  private var row: WorktreeRowModel? {
    orderedRows.indices.contains(index) ? orderedRows[index] : nil
  }

  private var title: String {
    guard let row else { return "Worktree \(index + 1)" }
    let repositoryName = store.repositories.repositoryName(for: row.repositoryID) ?? "Repository"
    return "\(repositoryName) — \(row.name)"
  }

  var body: some View {
    Button(title) {
      guard let row else { return }
      store.send(.repositories(.selectWorktree(row.id)))
    }
    .appKeyboardShortcut(shortcut)
    .help("Switch to \(title) (\(shortcut?.display ?? "none"))")
    .disabled(row == nil)
  }
}

private struct ArchiveWorktreeActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct OpenSelectedWorktreeActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct DeleteWorktreeActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct ConfirmWorktreeActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var openSelectedWorktreeAction: (() -> Void)? {
    get { self[OpenSelectedWorktreeActionKey.self] }
    set { self[OpenSelectedWorktreeActionKey.self] = newValue }
  }

  var confirmWorktreeAction: (() -> Void)? {
    get { self[ConfirmWorktreeActionKey.self] }
    set { self[ConfirmWorktreeActionKey.self] = newValue }
  }

  var archiveWorktreeAction: (() -> Void)? {
    get { self[ArchiveWorktreeActionKey.self] }
    set { self[ArchiveWorktreeActionKey.self] = newValue }
  }

  var deleteWorktreeAction: (() -> Void)? {
    get { self[DeleteWorktreeActionKey.self] }
    set { self[DeleteWorktreeActionKey.self] = newValue }
  }

  var runScriptAction: (() -> Void)? {
    get { self[RunScriptActionKey.self] }
    set { self[RunScriptActionKey.self] = newValue }
  }

  var stopRunScriptAction: (() -> Void)? {
    get { self[StopRunScriptActionKey.self] }
    set { self[StopRunScriptActionKey.self] = newValue }
  }

  var visibleHotkeyWorktreeRows: [WorktreeRowModel]? {
    get { self[VisibleHotkeyWorktreeRowsKey.self] }
    set { self[VisibleHotkeyWorktreeRowsKey.self] = newValue }
  }
}

private struct RunScriptActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct StopRunScriptActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct VisibleHotkeyWorktreeRowsKey: FocusedValueKey {
  typealias Value = [WorktreeRowModel]
}
