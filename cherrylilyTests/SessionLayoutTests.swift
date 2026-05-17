import Foundation
import Testing

@testable import CherryLily

struct SessionLayoutTests {
  @Test func emptyLayoutSerializes() throws {
    let layout = SessionLayout(savedAt: Date(timeIntervalSince1970: 0), worktrees: [])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(layout)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SessionLayout.self, from: data)
    #expect(decoded == layout)
    #expect(decoded.version == 1)
  }

  @Test func roundtripWithSurfacesAndCWDs() throws {
    let surfaceID = SurfaceID()
    let surface = PersistedSurface(
      id: surfaceID,
      cwd: URL(fileURLWithPath: "/tmp/repo/wt/src")
    )
    let tab = PersistedTab(
      id: UUID(),
      title: "main",
      surfaces: [surface]
    )
    let worktree = PersistedWorktree(
      worktreeID: "/tmp/repo/wt",
      selectedTabID: tab.id,
      tabs: [tab]
    )
    let original = SessionLayout(savedAt: Date(timeIntervalSince1970: 1_700_000_000), worktrees: [worktree])

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SessionLayout.self, from: data)
    #expect(decoded == original)
  }

  @Test func versionFieldRejectsUnknownVersion() throws {
    let json = #"""
    {"version": 999, "savedAt": "2026-01-01T00:00:00Z", "worktrees": []}
    """#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(throws: DecodingError.self) {
      _ = try decoder.decode(SessionLayout.self, from: Data(json.utf8))
    }
  }

  @Test func allSurfaceIDsCollectsAcrossAllWorktrees() {
    let firstID = SurfaceID(); let secondID = SurfaceID(); let thirdID = SurfaceID()
    let layout = SessionLayout(
      savedAt: Date(),
      worktrees: [
        PersistedWorktree(worktreeID: "wt1", selectedTabID: nil, tabs: [
          PersistedTab(id: UUID(), title: "t1", surfaces: [
            PersistedSurface(id: firstID, cwd: nil),
            PersistedSurface(id: secondID, cwd: nil),
          ]),
        ]),
        PersistedWorktree(worktreeID: "wt2", selectedTabID: nil, tabs: [
          PersistedTab(id: UUID(), title: "t2", surfaces: [
            PersistedSurface(id: thirdID, cwd: nil),
          ]),
        ]),
      ]
    )
    #expect(Set(layout.allSurfaceIDs) == Set([firstID, secondID, thirdID]))
  }

  @Test func splitTreeRoundTripsThroughCodable() throws {
    let leftID = SurfaceID()
    let rightID = SurfaceID()
    let leftSurface = PersistedSurface(id: leftID, cwd: URL(fileURLWithPath: "/a"))
    let rightSurface = PersistedSurface(id: rightID, cwd: URL(fileURLWithPath: "/b"))
    let tree: PersistedSplitTree = .split(
      direction: .horizontal,
      ratio: 0.4,
      left: .leaf(leftSurface),
      right: .split(
        direction: .vertical,
        ratio: 0.7,
        left: .leaf(rightSurface),
        right: .leaf(PersistedSurface(id: SurfaceID(), cwd: nil))
      )
    )
    let tab = PersistedTab(
      id: UUID(),
      title: "split",
      surfaces: [leftSurface, rightSurface],
      splitTree: tree
    )
    let worktree = PersistedWorktree(worktreeID: "wt", selectedTabID: tab.id, tabs: [tab])
    let original = SessionLayout(savedAt: Date(timeIntervalSince1970: 1_700_000_000), worktrees: [worktree])

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SessionLayout.self, from: data)
    #expect(decoded == original)
    #expect(decoded.worktrees[0].tabs[0].splitTree == tree)
  }

  @Test func persistedTabDecodesWithoutSplitTreeForBackCompat() throws {
    let surfaceUUID = UUID().uuidString
    let tabUUID = UUID().uuidString
    let json = """
      {
        "version": 1,
        "savedAt": "2026-01-01T00:00:00Z",
        "worktrees": [{
          "worktreeID": "/tmp/wt",
          "selectedTabID": "\(tabUUID)",
          "tabs": [{
            "id": "\(tabUUID)",
            "title": "old",
            "surfaces": [{
              "id": {"rawValue": "\(surfaceUUID)"},
              "cwd": null
            }]
          }]
        }]
      }
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SessionLayout.self, from: Data(json.utf8))
    #expect(decoded.worktrees.count == 1)
    let tab = decoded.worktrees[0].tabs[0]
    #expect(tab.title == "old")
    #expect(tab.surfaces.count == 1)
    #expect(tab.splitTree == nil)
  }

  @Test func persistedTabRoundTripsWithoutSplitTree() throws {
    let tab = PersistedTab(
      id: UUID(),
      title: "single",
      surfaces: [PersistedSurface(id: SurfaceID(), cwd: nil)]
    )
    let worktree = PersistedWorktree(worktreeID: "wt", selectedTabID: nil, tabs: [tab])
    let original = SessionLayout(savedAt: Date(timeIntervalSince1970: 1_700_000_000), worktrees: [worktree])

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SessionLayout.self, from: data)
    #expect(decoded == original)
    #expect(decoded.worktrees[0].tabs[0].splitTree == nil)
  }
}
