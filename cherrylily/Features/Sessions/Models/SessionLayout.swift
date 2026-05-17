import Foundation

// `Persisted*` prefix distinguishes on-disk DTOs from live runtime types
// (`Worktree`, `TerminalTabItem`, `GhosttySurfaceView`).

/// A snapshot of CherryLily's terminal layout: which worktrees are open,
/// which tabs they hold, which surfaces (Ghostty panes) live in those tabs,
/// and what working directory each surface was at when the snapshot was taken.
///
/// Persisted as JSON to `SessionPaths.layoutFile`.
nonisolated struct SessionLayout: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let savedAt: Date
  let worktrees: [PersistedWorktree]

  init(savedAt: Date, worktrees: [PersistedWorktree]) {
    self.version = Self.currentVersion
    self.savedAt = savedAt
    self.worktrees = worktrees
  }

  /// Custom decode that rejects unknown versions; lets us migrate later.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Self.currentVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .version,
        in: container,
        debugDescription: "Unsupported SessionLayout version \(version); expected \(Self.currentVersion)"
      )
    }
    self.version = version
    self.savedAt = try container.decode(Date.self, forKey: .savedAt)
    self.worktrees = try container.decode([PersistedWorktree].self, forKey: .worktrees)
  }

  /// Flattens all SurfaceIDs across every worktree/tab. Used by orphan reconciliation.
  var allSurfaceIDs: [SurfaceID] {
    worktrees.flatMap { worktree in worktree.tabs.flatMap { tab in tab.surfaces.map(\.id) } }
  }

  private enum CodingKeys: String, CodingKey {
    case version, savedAt, worktrees
  }
}

nonisolated struct PersistedWorktree: Codable, Equatable, Sendable {
  let worktreeID: String
  let selectedTabID: UUID?
  let tabs: [PersistedTab]
}

nonisolated struct PersistedTab: Codable, Equatable, Sendable {
  let id: UUID
  let title: String
  /// Flat list of all surfaces in this tab. Kept for back-compat and for
  /// `SessionLayout.allSurfaceIDs` (orphan reconciliation). When `splitTree`
  /// is present, it is the source of truth for restore.
  let surfaces: [PersistedSurface]
  /// Full split shape captured at snapshot time. `nil` for single-pane tabs,
  /// or when decoding an older `layout.json` written before Phase 6. When non-nil,
  /// `restoreTabs(from:)` uses this to rebuild the split layout; otherwise it
  /// falls back to restoring just `surfaces.first`.
  let splitTree: PersistedSplitTree?

  init(id: UUID, title: String, surfaces: [PersistedSurface], splitTree: PersistedSplitTree? = nil) {
    self.id = id
    self.title = title
    self.surfaces = surfaces
    self.splitTree = splitTree
  }

  /// Custom decode so older layout files (no `splitTree` key) decode cleanly with `splitTree == nil`.
  /// Swift's auto-synthesized decoder treats a missing key on an optional as `nil` already, but spell
  /// this out so the behavior is explicit and survives future field reordering.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(UUID.self, forKey: .id)
    self.title = try container.decode(String.self, forKey: .title)
    self.surfaces = try container.decode([PersistedSurface].self, forKey: .surfaces)
    self.splitTree = try container.decodeIfPresent(PersistedSplitTree.self, forKey: .splitTree)
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, surfaces, splitTree
  }
}

nonisolated struct PersistedSurface: Codable, Equatable, Sendable {
  let id: SurfaceID
  /// Captured working directory at snapshot time. Restore launches the new shell with `-c <cwd>`.
  let cwd: URL?
}

/// Recursive on-disk shape that mirrors the runtime `SplitTree.Node` enum. Used to
/// persist the full split layout of a tab so multi-pane sessions can be restored.
nonisolated indirect enum PersistedSplitTree: Codable, Equatable, Sendable {
  case leaf(PersistedSurface)
  case split(direction: PersistedSplitDirection, ratio: Double, left: PersistedSplitTree, right: PersistedSplitTree)
}

nonisolated enum PersistedSplitDirection: String, Codable, Sendable {
  case horizontal
  case vertical
}
