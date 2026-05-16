import Foundation
import Testing

@testable import CherryLily

struct SessionLayoutStoreTests {
  private static func makeTempPaths() -> SessionPaths {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "cl-layout-store-test-\(UUID().uuidString)")
    return SessionPaths(root: temp)
  }

  @Test func savedLayoutCanBeRead() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = SessionLayoutStore(paths: paths)
    let surfaceID = SurfaceID()
    let layout = SessionLayout(
      savedAt: Date(timeIntervalSince1970: 1_700_000_000),
      worktrees: [
        PersistedWorktree(worktreeID: "wt", selectedTabID: nil, tabs: [
          PersistedTab(id: UUID(), title: "t", surfaces: [
            PersistedSurface(id: surfaceID, cwd: URL(fileURLWithPath: "/tmp")),
          ]),
        ]),
      ]
    )
    try store.save(layout)
    let loaded = try store.load()
    #expect(loaded == layout)
  }

  @Test func loadReturnsNilWhenFileMissing() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = SessionLayoutStore(paths: paths)
    #expect(try store.load() == nil)
  }

  @Test func loadReturnsNilForCorruptedFile() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    try Data("not json".utf8).write(to: paths.layoutFile)
    let store = SessionLayoutStore(paths: paths)
    #expect(try store.load() == nil)
  }

  @Test func saveOverwritesExistingFile() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = SessionLayoutStore(paths: paths)
    let first = SessionLayout(savedAt: Date(timeIntervalSince1970: 1), worktrees: [])
    let second = SessionLayout(savedAt: Date(timeIntervalSince1970: 2), worktrees: [])
    try store.save(first)
    try store.save(second)
    let loaded = try store.load()
    #expect(loaded?.savedAt == Date(timeIntervalSince1970: 2))
  }
}
