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
  let surfaces: [PersistedSurface]
}

nonisolated struct PersistedSurface: Codable, Equatable, Sendable {
  let id: SurfaceID
  /// Captured working directory at snapshot time. Restore launches the new shell with `-c <cwd>`.
  let cwd: URL?
}
