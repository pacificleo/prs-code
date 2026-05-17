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
///
/// IMPORTANT: Multi-pane (split-tree) capture is intentionally disabled until the
/// matching restore path lands. The orphan reconciler relies on
/// `SessionLayout.allSurfaceIDs` matching the surfaces we can actually rehydrate.
/// If we captured every leaf but only restored the leftmost, the reconciler would
/// see the dropped panes' SurfaceIDs in `allSurfaceIDs`, treat them as live, and
/// never kill the associated tmux sessions — a permanent leak. So today we emit
/// only the leftmost leaf per tab, and the `splitTree` field is always nil even
/// when the live tab has multiple panes.
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
          // Capture only the first surface/cwd so the persisted `allSurfaceIDs`
          // matches the leftmost-leaf-only restore. Additional panes are dropped
          // on purpose — see the type-level comment above.
          let leftmostSurfaceID = tab.surfaceIDs.first
          let leftmostCwd = tab.cwds.first ?? nil
          let surfaces: [PersistedSurface]
          if let leftmostSurfaceID {
            surfaces = [PersistedSurface(id: SurfaceID(rawValue: leftmostSurfaceID), cwd: leftmostCwd)]
          } else {
            surfaces = []
          }
          return PersistedTab(
            id: tab.tabID,
            title: tab.title,
            surfaces: surfaces,
            splitTree: nil
          )
        }
      )
    }
    return SessionLayout(savedAt: now, worktrees: worktrees)
  }
}
