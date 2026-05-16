import Foundation

/// Pure-function reconciliation of three sets of state:
///   - `expectedSurfaceIDs`: what the layout file says should exist
///   - `liveTmuxSessionNames`: what tmux currently holds
///   - `storedScrollbackIDs`: what files exist in the sessions directory
///
/// Produces a `Plan` describing actions needed to reach a consistent state.
/// The caller issues the actual side effects.
nonisolated enum OrphanReconciler {
  struct Plan: Equatable, Sendable {
    /// Tmux session names whose corresponding SurfaceID is not in the layout — kill them.
    /// Sessions whose names don't parse as `cl_<uuid>` are left alone (not ours).
    var sessionsToKill: [String]

    /// SurfaceIDs whose scrollback file exists but who aren't in the layout — delete files.
    var scrollbackFilesToDelete: [SurfaceID]

    /// SurfaceIDs in the layout that don't have a live tmux session — create one.
    var surfacesNeedingFreshSession: [SurfaceID]

    /// Subset of `surfacesNeedingFreshSession` for which a scrollback file exists — replay it.
    var surfacesEligibleForReplay: [SurfaceID]

    /// SurfaceIDs in the layout that already have a live session — just attach.
    var surfacesAlreadyAlive: [SurfaceID]
  }

  static func reconcile(
    expectedSurfaceIDs: [SurfaceID],
    liveTmuxSessionNames: [String],
    storedScrollbackIDs: [SurfaceID]
  ) -> Plan {
    let expectedSet = Set(expectedSurfaceIDs)
    let storedSet = Set(storedScrollbackIDs)

    // For each live session name, parse SurfaceID. If it parses but isn't expected, kill.
    var sessionsToKill: [String] = []
    var liveSurfaceIDs = Set<SurfaceID>()
    for name in liveTmuxSessionNames {
      guard let surfaceID = SurfaceID(tmuxSessionName: name) else {
        // Not ours — leave alone
        continue
      }
      if expectedSet.contains(surfaceID) {
        liveSurfaceIDs.insert(surfaceID)
      } else {
        sessionsToKill.append(name)
      }
    }

    // Scrollback files whose surface ID is not in the layout → delete
    let scrollbackFilesToDelete = storedScrollbackIDs.filter { !expectedSet.contains($0) }

    // Surfaces in layout: alive vs need-fresh; among need-fresh, replay-eligible if file exists
    var alive: [SurfaceID] = []
    var needsFresh: [SurfaceID] = []
    var eligibleForReplay: [SurfaceID] = []
    for id in expectedSurfaceIDs {
      if liveSurfaceIDs.contains(id) {
        alive.append(id)
      } else {
        needsFresh.append(id)
        if storedSet.contains(id) {
          eligibleForReplay.append(id)
        }
      }
    }

    return Plan(
      sessionsToKill: sessionsToKill,
      scrollbackFilesToDelete: scrollbackFilesToDelete,
      surfacesNeedingFreshSession: needsFresh,
      surfacesEligibleForReplay: eligibleForReplay,
      surfacesAlreadyAlive: alive
    )
  }
}
