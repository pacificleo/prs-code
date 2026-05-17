import Foundation
import Testing

@testable import CherryLily

struct SessionDataClearerTests {
  private static func makePaths() -> SessionPaths {
    SessionPaths(
      root: URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "cl-clear-test-\(UUID().uuidString)")
    )
  }

  @Test func clearRemovesLayoutFile() throws {
    let paths = Self.makePaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try paths.ensureDirectoriesExist()
    try Data("{}".utf8).write(to: paths.layoutFile)
    #expect(FileManager.default.fileExists(atPath: paths.layoutFile.path))

    SessionDataClearer(paths: paths).clearSavedData()

    #expect(!FileManager.default.fileExists(atPath: paths.layoutFile.path))
  }

  @Test func clearRemovesAllScrollbackFiles() throws {
    let paths = Self.makePaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try paths.ensureDirectoriesExist()
    let id1 = SurfaceID()
    let id2 = SurfaceID()
    try Data("a".utf8).write(to: paths.scrollbackFile(for: id1))
    try Data("b".utf8).write(to: paths.scrollbackFile(for: id2))

    SessionDataClearer(paths: paths).clearSavedData()

    #expect(!FileManager.default.fileExists(atPath: paths.scrollbackFile(for: id1).path))
    #expect(!FileManager.default.fileExists(atPath: paths.scrollbackFile(for: id2).path))
  }

  @Test func clearLeavesTmuxConfigFile() throws {
    let paths = Self.makePaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try paths.ensureDirectoriesExist()
    try Data("# config".utf8).write(to: paths.tmuxConfigFile)

    SessionDataClearer(paths: paths).clearSavedData()

    // tmux.conf is managed config — survives "clear saved sessions"
    #expect(FileManager.default.fileExists(atPath: paths.tmuxConfigFile.path))
  }

  @Test func clearIsIdempotent() throws {
    let paths = Self.makePaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try paths.ensureDirectoriesExist()
    // No files exist; clearing should not throw
    SessionDataClearer(paths: paths).clearSavedData()
    // Second clear also fine
    SessionDataClearer(paths: paths).clearSavedData()
    #expect(Bool(true))
  }
}
