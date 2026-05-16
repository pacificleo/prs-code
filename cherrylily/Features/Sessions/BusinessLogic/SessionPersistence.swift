import Foundation

private nonisolated let sessionPersistenceLogger = SupaLogger("Sessions")

/// Top-level orchestrator for session persistence. Composes the Phase 1 primitives
/// (`SessionLayoutStore`, `ScrollbackStore`, `TmuxClient`, `OrphanReconciler`)
/// into the operations CherryLily needs at app boundaries:
///   - `restoreLayout()` — read the persisted layout on app launch
///   - `writeLayout(_:)` — write a layout on quit
///   - `captureAll(for:)` — capture scrollback per surface, in parallel
///   - `reconcileOrphans(against:)` — kill orphan tmux sessions and delete orphan files
///
/// `@MainActor` because it's wired into app delegate / TCA effects. Heavy I/O is
/// offloaded via `Task.detached` inside the primitives themselves.
@MainActor
final class SessionPersistence {
  let paths: SessionPaths
  private let layoutStore: SessionLayoutStore
  private let scrollbackStore: ScrollbackStore
  private let tmuxClient: TmuxClient

  init(paths: SessionPaths = SessionPaths()) {
    self.paths = paths
    self.layoutStore = SessionLayoutStore(paths: paths)
    self.scrollbackStore = ScrollbackStore(paths: paths)
    self.tmuxClient = TmuxClient(
      executableURL: TmuxBinary.bundledURL,
      socketName: paths.tmuxSocketName
    )
  }

  /// Reads the persisted layout if present. Returns nil if no file exists or the file
  /// is corrupt (corrupt = log + nil; the user gets a fresh start, never a crash).
  func restoreLayout() throws -> SessionLayout? {
    try layoutStore.load()
  }

  /// Writes a layout. Idempotent across the directory-create step.
  func writeLayout(_ layout: SessionLayout) throws {
    try paths.ensureDirectoriesExist()
    try layoutStore.save(layout)
  }

  /// Captures scrollback for every surface in the supplied layout. Each capture is a
  /// separate tmux subprocess; runs in parallel via `TaskGroup`.
  /// Returns the count of successful captures (failures are logged, not thrown).
  @discardableResult
  func captureAll(for layout: SessionLayout) async -> Int {
    var successCount = 0
    await withTaskGroup(of: Bool.self) { group in
      for surfaceID in layout.allSurfaceIDs {
        group.addTask { [tmuxClient, scrollbackStore] in
          await Self.captureOne(
            surfaceID: surfaceID,
            tmuxClient: tmuxClient,
            scrollbackStore: scrollbackStore
          )
        }
      }
      for await success in group where success {
        successCount += 1
      }
    }
    return successCount
  }

  /// Capture one surface — separate static to avoid main-actor capture in TaskGroup.
  private static func captureOne(
    surfaceID: SurfaceID,
    tmuxClient: TmuxClient,
    scrollbackStore: ScrollbackStore
  ) async -> Bool {
    do {
      let rawBytes = try await tmuxClient.capturePane(
        sessionName: surfaceID.tmuxSessionName,
        scrollbackLimit: 50_000  // hardcoded for now; Phase 4 reads from settings
      )
      let sanitized = ScrollbackStore.sanitize(rawBytes)
      try scrollbackStore.write(bytes: sanitized, for: surfaceID)
      return true
    } catch {
      sessionPersistenceLogger.warning(
        "capture failed for \(surfaceID.tmuxSessionName): \(error)"
      )
      return false
    }
  }

  /// Runs orphan reconciliation: kills tmux sessions whose IDs aren't in the layout,
  /// deletes scrollback files whose IDs aren't in the layout.
  /// Errors are logged, not thrown — best-effort cleanup.
  func reconcileOrphans(against layout: SessionLayout) async {
    do {
      let live = try await tmuxClient.listSessionNames()
      let stored = try scrollbackStore.storedSurfaceIDs()

      let plan = OrphanReconciler.reconcile(
        expectedSurfaceIDs: layout.allSurfaceIDs,
        liveTmuxSessionNames: live,
        storedScrollbackIDs: stored
      )

      for sessionName in plan.sessionsToKill {
        do {
          try await tmuxClient.killSession(named: sessionName)
        } catch {
          sessionPersistenceLogger.warning(
            "orphan session kill failed \(sessionName): \(error)"
          )
        }
      }

      for surfaceID in plan.scrollbackFilesToDelete {
        do {
          try scrollbackStore.delete(for: surfaceID)
        } catch {
          sessionPersistenceLogger.warning(
            "orphan scrollback delete failed \(surfaceID.tmuxSessionName): \(error)"
          )
        }
      }
    } catch {
      sessionPersistenceLogger.warning("orphan reconcile failed: \(error)")
    }
  }
}
