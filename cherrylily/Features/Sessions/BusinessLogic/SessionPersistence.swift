import Foundation

private nonisolated let sessionPersistenceLogger = SupaLogger("Sessions")

/// Aggregate outcome of `captureAll`. The caller decides how to surface
/// disk-full failures (the design spec calls for a one-time alert).
nonisolated struct CaptureReport: Sendable, Equatable {
  var successCount: Int = 0
  var diskFullCount: Int = 0
  var otherFailureCount: Int = 0
}

private enum CaptureOutcome {
  case success
  case diskFull
  case other
}

/// Top-level orchestrator for session persistence. Composes the Phase 1 primitives
/// (`SessionLayoutStore`, `ScrollbackStore`, `TmuxClient`, `OrphanReconciler`)
/// into the operations CherryLily needs at app boundaries:
///   - `restoreLayout()` — read the persisted layout on app launch
///   - `writeLayout(_:)` — write a layout on quit
///   - `captureAll(for:)` — capture scrollback per surface, in parallel
///   - `reconcileOrphans(against:)` — kill orphan tmux sessions and delete orphan files
///
/// Intentionally NOT `@MainActor`. `applicationWillTerminate` parks the main thread
/// inside a DispatchSemaphore waiting for `captureAll` to finish; a MainActor-bound
/// `captureAll` would deadlock because the Task it spawns can never acquire the
/// main thread to resume. All stored properties are `Sendable` value types, so the
/// class is safely `Sendable`.
final class SessionPersistence: Sendable {
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
  /// Returns a `CaptureReport` tallying successes and failure modes (failures are
  /// logged here; the caller decides whether to surface them to the user).
  @discardableResult
  func captureAll(for layout: SessionLayout, scrollbackLimit: Int?) async -> CaptureReport {
    // For "Unlimited" (nil) cap at 1_000_000 — same convention as the tmux.conf
    // bootstrap; avoids unbounded memory on very long captures.
    let effectiveLimit = scrollbackLimit ?? 1_000_000
    var report = CaptureReport()
    await withTaskGroup(of: CaptureOutcome.self) { group in
      for surfaceID in layout.allSurfaceIDs {
        group.addTask { [tmuxClient, scrollbackStore] in
          await Self.captureOne(
            surfaceID: surfaceID,
            scrollbackLimit: effectiveLimit,
            tmuxClient: tmuxClient,
            scrollbackStore: scrollbackStore
          )
        }
      }
      for await outcome in group {
        switch outcome {
        case .success: report.successCount += 1
        case .diskFull: report.diskFullCount += 1
        case .other: report.otherFailureCount += 1
        }
      }
    }
    return report
  }

  /// Capture one surface — separate static to avoid main-actor capture in TaskGroup.
  private static func captureOne(
    surfaceID: SurfaceID,
    scrollbackLimit: Int,
    tmuxClient: TmuxClient,
    scrollbackStore: ScrollbackStore
  ) async -> CaptureOutcome {
    do {
      let rawBytes = try await tmuxClient.capturePane(
        sessionName: surfaceID.tmuxSessionName,
        scrollbackLimit: scrollbackLimit
      )
      let sanitized = ScrollbackStore.sanitize(rawBytes)
      try scrollbackStore.write(bytes: sanitized, for: surfaceID)
      return .success
    } catch {
      if Self.isDiskFull(error) {
        sessionPersistenceLogger.warning(
          "capture for \(surfaceID.tmuxSessionName) failed: disk full"
        )
        return .diskFull
      }
      sessionPersistenceLogger.warning(
        "capture failed for \(surfaceID.tmuxSessionName): \(error)"
      )
      return .other
    }
  }

  /// POSIX errno 28 (`ENOSPC`) means out of disk space. Cocoa wraps this
  /// in NSCocoaErrorDomain with `.fileWriteOutOfSpaceError` (640); the
  /// underlying NSError chain often carries POSIXError as well.
  private static func isDiskFull(_ error: Error) -> Bool {
    if let posix = error as? POSIXError, posix.code == .ENOSPC { return true }
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
      return true
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
      return isDiskFull(underlying)
    }
    return false
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
