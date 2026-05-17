import Foundation

/// Minimum surface area required to snapshot a worktree's tabs. Lets `WorktreeTerminalState`
/// (live, complex) and test fakes both feed into the builder uniformly.
@MainActor
protocol WorktreeStateSnapshotting {
  var snapshot: WorktreeStateSnapshot { get }
}

nonisolated struct WorktreeStateSnapshot: Sendable {
  let selectedTabID: UUID?
  let tabs: [WorktreeTabSnapshot]
}

nonisolated struct WorktreeTabSnapshot: Sendable {
  let tabID: UUID
  let title: String
  let surfaceIDs: [UUID]
  let cwds: [URL?]
  /// Full split shape for this tab, or nil for a single-pane tab. When non-nil,
  /// `LayoutSnapshotBuilder` writes it through to `PersistedTab.splitTree` so
  /// restore can rebuild the layout.
  let splitTree: PersistedSplitTree?

  init(
    tabID: UUID,
    title: String,
    surfaceIDs: [UUID],
    cwds: [URL?],
    splitTree: PersistedSplitTree? = nil
  ) {
    self.tabID = tabID
    self.title = title
    self.surfaceIDs = surfaceIDs
    self.cwds = cwds
    self.splitTree = splitTree
  }
}

/// Walks live `WorktreeTerminalState` instances and produces a `SessionLayout` DTO
/// suitable for persistence. Pure — no side effects.
@MainActor
enum LayoutSnapshotBuilder {
  static func build(
    worktreeStates: [(Worktree.ID, any WorktreeStateSnapshotting)],
    now: Date
  ) -> SessionLayout {
    let worktrees = worktreeStates.map { worktreeID, state in
      let snap = state.snapshot
      return PersistedWorktree(
        worktreeID: worktreeID,
        selectedTabID: snap.selectedTabID,
        tabs: snap.tabs.map { tab in
          PersistedTab(
            id: tab.tabID,
            title: tab.title,
            surfaces: zip(tab.surfaceIDs, tab.cwds).map { surfaceID, cwd in
              PersistedSurface(
                id: SurfaceID(rawValue: surfaceID),
                cwd: cwd
              )
            },
            splitTree: tab.splitTree
          )
        }
      )
    }
    return SessionLayout(savedAt: now, worktrees: worktrees)
  }
}
