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

  @Test func saveCreatesParentDirectoriesIfMissing() throws {
    let paths = Self.makeTempPaths()
    // Note: do NOT call ensureDirectoriesExist here; the test verifies save() does it
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = SessionLayoutStore(paths: paths)
    let layout = SessionLayout(savedAt: Date(timeIntervalSince1970: 1), worktrees: [])
    try store.save(layout)
    #expect(FileManager.default.fileExists(atPath: paths.layoutFile.path))
  }

  @Test func loadReturnsNilForUnknownVersion() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    // Hand-write a layout with a version SessionLayout doesn't recognize.
    let json = #"""
    {"version": 999, "savedAt": "2026-01-01T00:00:00Z", "worktrees": []}
    """#
    try Data(json.utf8).write(to: paths.layoutFile)
    let store = SessionLayoutStore(paths: paths)
    // SessionLayout's custom decoder throws DecodingError; SessionLayoutStore.load() catches it
    // and returns nil (with a warning logged — verified by reading layoutLogger output if needed).
    #expect(try store.load() == nil)
  }

  @Test func loadReturnsNilForEmptyFile() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    try Data().write(to: paths.layoutFile)
    let store = SessionLayoutStore(paths: paths)
    #expect(try store.load() == nil)
  }
}
