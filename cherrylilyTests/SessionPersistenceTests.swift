import Foundation
import Testing

@testable import CherryLily

@MainActor
struct SessionPersistenceTests {
  private static func makePaths() -> SessionPaths {
    SessionPaths(
      root: URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "cl-persistence-test-\(UUID().uuidString)")
    )
  }

  @Test func restoreLayoutReturnsNilWhenNoFileExists() throws {
    let paths = Self.makePaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let persistence = SessionPersistence(paths: paths)

    #expect(try persistence.restoreLayout() == nil)
  }

  @Test func restoreLayoutReadsPreviouslyWrittenLayout() throws {
    let paths = Self.makePaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try paths.ensureDirectoriesExist()

    let store = SessionLayoutStore(paths: paths)
    let written = SessionLayout(
      savedAt: Date(timeIntervalSince1970: 1_000_000),
      worktrees: [
        PersistedWorktree(worktreeID: "/tmp/repo", selectedTabID: nil, tabs: []),
      ]
    )
    try store.save(written)

    let persistence = SessionPersistence(paths: paths)
    let restored = try persistence.restoreLayout()
    #expect(restored?.worktrees.first?.worktreeID == "/tmp/repo")
  }

  @Test func writeLayoutCreatesFile() throws {
    let paths = Self.makePaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let persistence = SessionPersistence(paths: paths)

    let layout = SessionLayout(savedAt: Date(timeIntervalSince1970: 2_000_000), worktrees: [])
    try persistence.writeLayout(layout)

    #expect(FileManager.default.fileExists(atPath: paths.layoutFile.path))
  }

  @Test func writeLayoutIsIdempotent() throws {
    let paths = Self.makePaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let persistence = SessionPersistence(paths: paths)

    let layout = SessionLayout(savedAt: Date(timeIntervalSince1970: 2_000_000), worktrees: [])
    try persistence.writeLayout(layout)
    // Should not throw on second write
    try persistence.writeLayout(layout)

    #expect(FileManager.default.fileExists(atPath: paths.layoutFile.path))
  }
}
