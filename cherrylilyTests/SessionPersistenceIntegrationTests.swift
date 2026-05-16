import Foundation
import Testing

@testable import CherryLily

struct SessionPersistenceIntegrationTests {
  private static func makeIsolatedSetup() -> (paths: SessionPaths, client: TmuxClient) {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "cl-int-test-\(UUID().uuidString)")
    let paths = SessionPaths(root: temp)
    let socket = "cl-int-\(UUID().uuidString.prefix(8).lowercased())"
    let client = TmuxClient(executableURL: TmuxBinary.bundledURL, socketName: socket)
    return (paths, client)
  }

  @Test func reconciliationCleansOrphanSessionsAndFiles() async throws {
    try #require(TmuxBinary.isAvailable)
    let (paths, client) = Self.makeIsolatedSetup()
    try paths.ensureDirectoriesExist()
    defer {
      try? client.killServer()
      try? FileManager.default.removeItem(at: paths.root)
    }

    let kept = SurfaceID()
    let removedFromLayout = SurfaceID()

    // Setup: one expected surface (kept), one orphan tmux session, one orphan scrollback file
    let layoutStore = SessionLayoutStore(paths: paths)
    let scrollbackStore = ScrollbackStore(paths: paths)

    let layout = SessionLayout(
      savedAt: Date(),
      worktrees: [
        PersistedWorktree(worktreeID: "wt", selectedTabID: nil, tabs: [
          PersistedTab(id: UUID(), title: "t", surfaces: [
            PersistedSurface(id: kept, cwd: nil),
          ]),
        ]),
      ]
    )
    try layoutStore.save(layout)
    try scrollbackStore.write(bytes: Data("hi".utf8), for: removedFromLayout)
    try await client.createSession(named: removedFromLayout.tmuxSessionName, workingDirectory: nil)

    // Reconcile
    let liveSessions = try await client.listSessionNames()
    let storedFiles = try scrollbackStore.storedSurfaceIDs()
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: layout.allSurfaceIDs,
      liveTmuxSessionNames: liveSessions,
      storedScrollbackIDs: storedFiles
    )

    // Apply side effects from plan
    for sessionName in plan.sessionsToKill {
      try await client.killSession(named: sessionName)
    }
    for id in plan.scrollbackFilesToDelete {
      try scrollbackStore.delete(for: id)
    }

    // Verify
    let postKillSessions = try await client.listSessionNames()
    let postDeleteFiles = try scrollbackStore.storedSurfaceIDs()
    #expect(!postKillSessions.contains(removedFromLayout.tmuxSessionName))
    #expect(!postDeleteFiles.contains(removedFromLayout))

    // The kept surface was not in tmux to begin with — verify the plan flagged it for fresh creation
    #expect(plan.surfacesNeedingFreshSession == [kept])
    #expect(plan.surfacesEligibleForReplay.isEmpty)  // no scrollback file for kept
  }
}
