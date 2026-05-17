import Foundation
import Testing

@testable import CherryLily

@MainActor
struct LayoutSnapshotBuilderTests {
  @Test func snapshotIsEmptyWhenNoWorktrees() {
    let result = LayoutSnapshotBuilder.build(
      worktreeStates: [],
      now: Date(timeIntervalSince1970: 1_000_000)
    )

    #expect(result.worktrees.isEmpty)
    #expect(result.savedAt == Date(timeIntervalSince1970: 1_000_000))
    #expect(result.version == SessionLayout.currentVersion)
  }

  @Test func snapshotCapturesWorktreeWithSingleTabAndSurface() {
    let surfaceUUID = UUID()
    let tabID = UUID()
    let cwd = URL(fileURLWithPath: "/tmp/work")

    let fake = FakeSnapshottingState(
      selectedTabID: tabID,
      tabs: [
        .init(tabID: tabID, title: "main", surfaceIDs: [surfaceUUID], cwds: [cwd]),
      ]
    )

    let result = LayoutSnapshotBuilder.build(
      worktreeStates: [("/tmp/repo", fake)],
      now: Date(timeIntervalSince1970: 1_000_000)
    )

    #expect(result.worktrees.count == 1)
    let worktree = result.worktrees[0]
    #expect(worktree.worktreeID == "/tmp/repo")
    #expect(worktree.selectedTabID == tabID)
    #expect(worktree.tabs.count == 1)
    let tab = worktree.tabs[0]
    #expect(tab.id == tabID)
    #expect(tab.title == "main")
    #expect(tab.surfaces.count == 1)
    #expect(tab.surfaces[0].id.rawValue == surfaceUUID)
    #expect(tab.surfaces[0].cwd == cwd)
  }

  @Test func snapshotHandlesMultipleSurfacesPerTab() {
    let surfaceA = UUID()
    let surfaceB = UUID()
    let tabID = UUID()
    let cwdA = URL(fileURLWithPath: "/a")
    let cwdB = URL(fileURLWithPath: "/b")

    let fake = FakeSnapshottingState(
      selectedTabID: tabID,
      tabs: [.init(tabID: tabID, title: "split", surfaceIDs: [surfaceA, surfaceB], cwds: [cwdA, cwdB])]
    )

    let result = LayoutSnapshotBuilder.build(
      worktreeStates: [("/repo", fake)],
      now: Date()
    )

    let surfaces = result.worktrees[0].tabs[0].surfaces
    #expect(surfaces.count == 2)
    #expect(surfaces[0].id.rawValue == surfaceA)
    #expect(surfaces[0].cwd == cwdA)
    #expect(surfaces[1].id.rawValue == surfaceB)
    #expect(surfaces[1].cwd == cwdB)
  }

  @Test func snapshotPreservesNilCwd() {
    let surfaceID = UUID()
    let tabID = UUID()

    let fake = FakeSnapshottingState(
      selectedTabID: nil,
      tabs: [.init(tabID: tabID, title: "no-pwd", surfaceIDs: [surfaceID], cwds: [nil])]
    )

    let result = LayoutSnapshotBuilder.build(
      worktreeStates: [("/repo", fake)],
      now: Date()
    )

    #expect(result.worktrees[0].selectedTabID == nil)
    #expect(result.worktrees[0].tabs[0].surfaces[0].cwd == nil)
  }

  @Test func snapshotWritesSplitTreeForHorizontalTwoPaneTab() {
    let leftUUID = UUID()
    let rightUUID = UUID()
    let tabID = UUID()
    let leftCwd = URL(fileURLWithPath: "/left")
    let rightCwd = URL(fileURLWithPath: "/right")
    let splitTree: PersistedSplitTree = .split(
      direction: .horizontal,
      ratio: 0.5,
      left: .leaf(PersistedSurface(id: SurfaceID(rawValue: leftUUID), cwd: leftCwd)),
      right: .leaf(PersistedSurface(id: SurfaceID(rawValue: rightUUID), cwd: rightCwd))
    )

    let fake = FakeSnapshottingState(
      selectedTabID: tabID,
      tabs: [
        .init(
          tabID: tabID,
          title: "split",
          surfaceIDs: [leftUUID, rightUUID],
          cwds: [leftCwd, rightCwd],
          splitTree: splitTree
        ),
      ]
    )

    let result = LayoutSnapshotBuilder.build(
      worktreeStates: [("/repo", fake)],
      now: Date()
    )

    let tab = result.worktrees[0].tabs[0]
    #expect(tab.splitTree == splitTree)
    // Flat surfaces list still reflects both panes for orphan reconciliation.
    #expect(tab.surfaces.count == 2)
    #expect(tab.surfaces.map(\.id.rawValue) == [leftUUID, rightUUID])
  }

  @Test func snapshotSplitTreeIsNilForSinglePaneTab() {
    let surfaceUUID = UUID()
    let tabID = UUID()

    let fake = FakeSnapshottingState(
      selectedTabID: tabID,
      tabs: [.init(tabID: tabID, title: "solo", surfaceIDs: [surfaceUUID], cwds: [nil])]
    )

    let result = LayoutSnapshotBuilder.build(
      worktreeStates: [("/repo", fake)],
      now: Date()
    )

    #expect(result.worktrees[0].tabs[0].splitTree == nil)
  }
}

@MainActor
private struct FakeSnapshottingState: WorktreeStateSnapshotting {
  let selectedTabID: UUID?
  let tabs: [WorktreeTabSnapshot]

  var snapshot: WorktreeStateSnapshot {
    WorktreeStateSnapshot(selectedTabID: selectedTabID, tabs: tabs)
  }
}
