import Foundation
import Testing

@testable import CherryLily

struct OrphanReconcilerTests {
  @Test func emptyInputsProducesNoActions() {
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [],
      liveTmuxSessionNames: [],
      storedScrollbackIDs: []
    )
    #expect(plan.sessionsToKill.isEmpty)
    #expect(plan.scrollbackFilesToDelete.isEmpty)
    #expect(plan.surfacesNeedingFreshSession.isEmpty)
    #expect(plan.surfacesAlreadyAlive.isEmpty)
    #expect(plan.surfacesEligibleForReplay.isEmpty)
  }

  @Test func sessionWithMatchingExpectedIsAlive() {
    let id = SurfaceID()
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [id],
      liveTmuxSessionNames: [id.tmuxSessionName],
      storedScrollbackIDs: []
    )
    #expect(plan.surfacesAlreadyAlive == [id])
    #expect(plan.surfacesNeedingFreshSession.isEmpty)
    #expect(plan.sessionsToKill.isEmpty)
  }

  @Test func sessionWithoutExpectedIsKilled() {
    let id = SurfaceID()
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [],
      liveTmuxSessionNames: [id.tmuxSessionName],
      storedScrollbackIDs: []
    )
    #expect(plan.sessionsToKill == [id.tmuxSessionName])
  }

  @Test func nonClSessionNamesAreLeftAlone() {
    // A session that doesn't match the cl_<uuid> pattern was created by the user's
    // own tmux somehow (shouldn't happen with custom socket but defensive).
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [],
      liveTmuxSessionNames: ["my-personal-session"],
      storedScrollbackIDs: []
    )
    #expect(plan.sessionsToKill.isEmpty)
  }

  @Test func scrollbackFileWithoutExpectedIsDeleted() {
    let id = SurfaceID()
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [],
      liveTmuxSessionNames: [],
      storedScrollbackIDs: [id]
    )
    #expect(plan.scrollbackFilesToDelete == [id])
  }

  @Test func expectedWithoutSessionNeedsFreshSession() {
    let id = SurfaceID()
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [id],
      liveTmuxSessionNames: [],
      storedScrollbackIDs: []
    )
    #expect(plan.surfacesNeedingFreshSession == [id])
    #expect(plan.surfacesEligibleForReplay.isEmpty)
  }

  @Test func expectedWithoutSessionButWithScrollbackIsEligibleForReplay() {
    let id = SurfaceID()
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [id],
      liveTmuxSessionNames: [],
      storedScrollbackIDs: [id]
    )
    #expect(plan.surfacesNeedingFreshSession == [id])
    #expect(plan.surfacesEligibleForReplay == [id])
  }

  @Test func expectedWithLiveSessionDoesNotReplayEvenIfFileExists() {
    // Live session means we kept the in-memory state; replay would double-up
    let id = SurfaceID()
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [id],
      liveTmuxSessionNames: [id.tmuxSessionName],
      storedScrollbackIDs: [id]
    )
    #expect(plan.surfacesAlreadyAlive == [id])
    #expect(plan.surfacesNeedingFreshSession.isEmpty)
    #expect(plan.surfacesEligibleForReplay.isEmpty)
  }

  @Test func mixedScenarioProducesCorrectPlan() {
    // Reboot scenario: some sessions in layout, none alive in tmux, all have scrollback files
    let kept = SurfaceID()
    let alsoKept = SurfaceID()
    let removed = SurfaceID()        // in scrollback files but not in expected → file orphan
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [kept, alsoKept],
      liveTmuxSessionNames: [],
      storedScrollbackIDs: [kept, alsoKept, removed]
    )
    #expect(Set(plan.surfacesNeedingFreshSession) == Set([kept, alsoKept]))
    #expect(Set(plan.surfacesEligibleForReplay) == Set([kept, alsoKept]))
    #expect(plan.scrollbackFilesToDelete == [removed])
    #expect(plan.sessionsToKill.isEmpty)
  }
}
